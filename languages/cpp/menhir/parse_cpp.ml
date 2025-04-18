(* Yoann Padioleau
 *
 * Copyright (C) 2002-2013 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *
 *)
open Common
open Fpath_.Operators
module Flag = Flag_parsing
module PS = Parsing_stat
module FT = File_type
module Ast = Ast_cpp
module Flag_cpp = Flag_parsing_cpp
module T = Parser_cpp
module TH = Token_helpers_cpp
module Lexer = Lexer_cpp
module Log = Log_parser_cpp.Log
module LogLib = Log_lib_parsing.Log

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
 * A heuristic-based C/cpp/C++ parser.
 *
 * See "Parsing C/C++ Code without Pre-Preprocessing - Yoann Padioleau, CC'09"
 * avalaible at http://padator.org/papers/yacfe-cc09.pdf
 *)

(*****************************************************************************)
(* Error diagnostic *)
(*****************************************************************************)

let error_msg_tok tok = Parsing_helpers.error_message_info (TH.info_of_tok tok)

(*****************************************************************************)
(* Stats on what was passed/commentized  *)
(*****************************************************************************)

let commentized xs =
  xs
  |> List_.filter_map (function
       | T.TComment_Pp (cppkind, ii) ->
           if !Flag_cpp.filter_classic_passed then
             match cppkind with
             | Token_cpp.CppOther -> (
                 let s = Tok.content_of_tok ii in
                 match s with
                 | s when s =~ "KERN_.*" -> None
                 | s when s =~ "__.*" -> None
                 | _ -> Some ii)
             | Token_cpp.CppDirective
             | Token_cpp.CppAttr
             | Token_cpp.CppMacro ->
                 None
             | Token_cpp.CppMacroExpanded
             | Token_cpp.CppPassingNormal
             | Token_cpp.CppPassingCosWouldGetError ->
                 raise Todo
           else Some ii
       | T.TAny_Action ii -> Some ii
       | _ -> None)

let count_lines_commentized xs =
  let line = ref (-1) in
  let count = ref 0 in
  commentized xs
  |> List.iter (function
       | Tok.OriginTok pinfo
       | Tok.ExpandedTok (_, (pinfo, _)) ->
           let newline = pinfo.Tok.pos.line in
           if newline <> !line then (
             line := newline;
             incr count)
       | _ -> ());
  !count

(* See also problematic_lines and parsing_stat.ml *)

(* for most problematic tokens *)
let is_same_line_or_close line tok =
  TH.line_of_tok tok =|= line
  || TH.line_of_tok tok =|= line - 1
  || TH.line_of_tok tok =|= line - 2

(*****************************************************************************)
(* Lexing only *)
(*****************************************************************************)

(* called by parse below *)
let tokens input_source =
  Parsing_helpers.tokenize_all_and_adjust_pos input_source Lexer.token
    TH.visitor_info_of_tok TH.is_eof
[@@profiling]

(*****************************************************************************)
(* Fuzzy parsing *)
(*****************************************************************************)

let rec multi_grouped_list xs = xs |> List_.map multi_grouped

and multi_grouped = function
  | Token_views_cpp.Braces (tok1, xs, Some tok2) ->
      Ast_fuzzy.Braces (tokext tok1, multi_grouped_list xs, tokext tok2)
  | Token_views_cpp.Parens (tok1, xs, Some tok2) ->
      Ast_fuzzy.Parens (tokext tok1, multi_grouped_list_comma xs, tokext tok2)
  | Token_views_cpp.Angle (tok1, xs, Some tok2) ->
      Ast_fuzzy.Angle (tokext tok1, multi_grouped_list xs, tokext tok2)
  | Token_views_cpp.Tok tok -> (
      match Tok.content_of_tok (tokext tok) with
      | "..." -> Ast_fuzzy.Dots (tokext tok)
      | s when Ast_fuzzy.is_metavar s -> Ast_fuzzy.Metavar (s, tokext tok)
      | s -> Ast_fuzzy.Tok (s, tokext tok))
  | _ -> failwith "could not find closing brace/parens/angle"

and tokext tok_extended = TH.info_of_tok tok_extended.Token_views_cpp.t

and multi_grouped_list_comma xs =
  let rec aux acc xs =
    match xs with
    | [] ->
        if List_.null acc then []
        else [ Either.Left (acc |> List.rev |> multi_grouped_list) ]
    | x :: xs -> (
        match x with
        | Token_views_cpp.Tok tok when Tok.content_of_tok (tokext tok) = "," ->
            let before = acc |> List.rev |> multi_grouped_list in
            if List_.null before then aux [] xs
            else Either.Left before :: Either.Right (tokext tok) :: aux [] xs
        | _ -> aux (x :: acc) xs)
  in
  aux [] xs

(* This is similar to what I did for OPA. This is also similar
 * to what I do for parsing hacks, but this fuzzy AST can be useful
 * on its own, e.g. for a not too bad sgrep/spatch.
 *
 * note: this is similar to what cpplint/fblint of andrei does?
 *)
let parse_fuzzy file =
  Common.save_excursion Flag_parsing.sgrep_mode true (fun () ->
      let toks_orig = tokens (Parsing_helpers.file !!file) in
      let toks =
        toks_orig
        |> List_.exclude (fun x ->
               Token_helpers_cpp.is_comment x || Token_helpers_cpp.is_eof x)
      in
      let extended = toks |> List_.map Token_views_cpp.mk_token_extended in
      Parsing_hacks_cpp.find_template_inf_sup extended;
      let groups = Token_views_cpp.mk_multi extended in
      let trees = multi_grouped_list groups in
      let hooks =
        { Lib_ast_fuzzy.kind = TH.token_kind_of_tok; tokf = TH.info_of_tok }
      in
      (trees, Lib_ast_fuzzy.mk_tokens hooks toks_orig))

(*****************************************************************************)
(* Extract macros *)
(*****************************************************************************)

(* It can be used to parse the macros defined in a macro.h file. It
 * can also be used to try to extract the macros defined in the file
 * that we try to parse *)
let extract_macros file =
  Common.save_excursion Flag.verbose_lexing false (fun () ->
      let toks =
        tokens (* todo: ~profile:false *) (Parsing_helpers.file !!file)
      in
      let toks = Parsing_hacks_define.fix_tokens_define toks in
      Pp_token.extract_macros toks)
[@@profiling]

(* We used to have also a init_defs_builtins() so that we could use a
 * standard.h containing macros that were always useful, and a macros.h
 * that the user could customize for his own project.
 * But this was adding complexity so now we just have _defs and people
 * can call add_defs to add local macro definitions.
 *)

(* Why cache this?
 * Because the file comes from a flag, it's common to the full scan,
 * and there is no reason to repeat the work of reading and processing it.
 * Moreover, because it does not change during a scan, it's ok to do the
 * work > 1 times in case of a race.
 * Invariant: the hashtable is only read after being completely populated
 * in the function below. *)
let defs_cached = Atomic.make None

let create_defs (lang: Flag_cpp.language) =
  match lang with
  | Flag_cpp.C ->
    begin match Atomic.get defs_cached with
    | Some defs -> defs
    | None when Sys.file_exists !!(!Flag_parsing_cpp.macros_h) ->
      let file = !Flag_parsing_cpp.macros_h in
      let (defs : (string, Pp_token.define_body) Hashtbl.t) = Hashtbl.create 101 in
      (* if not (Sys.file_exists !!file) then
           failwith (spf "Could not find %s, have you set PFFF_HOME correctly?" !!file); *)
      Log.info (fun m -> m "Using %s macro file" !!file);
      let xs = extract_macros file in
      xs |> List.iter (fun (k, v) -> Hashtbl.replace defs k v);
      Atomic.set defs_cached (Some defs);
      defs
    | _ -> Hashtbl.create 101
    end
  | _ -> Hashtbl.create 101

(*****************************************************************************)
(* Error recovery *)
(*****************************************************************************)
(* see parsing_recovery_cpp.ml *)

(*****************************************************************************)
(* Consistency checking *)
(*****************************************************************************)
(* todo: a parsing_consistency_cpp.ml *)

(*****************************************************************************)
(* Helper for main entry point *)
(*****************************************************************************)
open Parsing_helpers

(* Hacked lex. This function use refs passed by parse.
 * 'tr' means 'token refs'. This is used mostly to enable
 * error recovery (This used to do lots of stuff, such as
 * calling some lookahead heuristics to reclassify
 * tokens such as TIdent into TIdent_Typeded but this is
 * now done in a fix_tokens style in parsing_hacks_typedef.ml.
 *)
let rec lexer_function tr lexbuf =
  match tr.rest with
  | [] ->
      Log.warn (fun m -> m "LEXER: ALREADY AT END");
      tr.current
  | v :: xs ->
      tr.rest <- xs;
      tr.current <- v;
      tr.passed <- v :: tr.passed;

      if !Flag.debug_lexer then
        Log.debug (fun m -> m "tok = %s" (Dumper.dump v));

      if TH.is_comment v then lexer_function (*~pass*) tr lexbuf else v

(* was a define ? *)
let passed_a_define tr =
  let xs = tr.passed |> List.rev |> List_.exclude TH.is_comment in
  if List.length xs >= 2 then
    match Common2.head_middle_tail xs with
    | T.TDefine _, _, T.TCommentNewline_DefineEndOfMacro _ -> true
    | _ -> false
  else (
    Log.warn (fun m -> m "WEIRD: length list of error recovery tokens < 2 ");
    false)

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)
(*
 * note: as now we go in two passes, there is first all the error message of
 * the lexer, and then the error of the parser. It is not anymore
 * interwinded.
 *
 * This function is reentrant as long as it's not interleaved within a single
 * domain, ie, as long as things continue to work as they do now.
 * The use of [Common.save_excursion] is safe in that scenario, because it
 * works with domain-local state.
 * The [defs] are created in a thread-safe way.
 *)
let parse_with_lang ?(lang = Flag_parsing_cpp.Cplusplus) file :
    (Ast.program, T.token) Parsing_result.t =
  let stat = Parsing_stat.default_stat !!file in
  let filelines = UFile.cat_array file in

  (* -------------------------------------------------- *)
  (* call lexer and get all the tokens *)
  (* -------------------------------------------------- *)
  let toks_orig = tokens (Parsing_helpers.file !!file) in

  let defs = create_defs lang in

  let toks =
    try Parsing_hacks.fix_tokens ~macro_defs:defs lang toks_orig with
    | Token_views_cpp.UnclosedSymbol s ->
        Log.warn (fun m -> m "unclosed symbol %s" s);
        if !Flag_cpp.debug_cplusplus then
          raise (Token_views_cpp.UnclosedSymbol s)
        else toks_orig
  in

  let tr = Parsing_helpers.mk_tokens_state toks in
  let lexbuf_fake = Lexing.from_function (fun _buf _n -> raise Impossible) in

  (* Why here? It's faster to do this once, and we don't need to change
   * that value after parsing starts. *)
  let error_recovery = Domain.DLS.get Flag.error_recovery in
  let show_parsing_error = Domain.DLS.get Flag.show_parsing_error in

  let rec loop () =
    let info = TH.info_of_tok tr.Parsing_helpers.current in
    (* todo?: I am not sure that it represents current_line, cos maybe
     * tr.current partipated in the previous parsing phase, so maybe tr.current
     * is not the first token of the next parsing phase. Same with checkpoint2.
     * It would be better to record when we have a } or ; in parser.mly,
     *  cos we know that they are the last symbols of external_declaration2.
     *)
    let checkpoint = Tok.line_of_tok info in
    (* bugfix: may not be equal to 'file' as after macro expansions we can
     * start to parse a new entity from the body of a macro, for instance
     * when parsing a define_machine() body, cf standard.h
     *)
    let checkpoint_file = Tok.file_of_tok info in

    tr.passed <- [];
    (* for some statistics *)
    let was_define = ref false in

    let parse_toplevel tr lexbuf_fake =
      Parser_cpp.toplevel (lexer_function tr) lexbuf_fake
    in

    let elem =
      try
        (* -------------------------------------------------- *)
        (* Call parser *)
        (* -------------------------------------------------- *)
        parse_toplevel tr lexbuf_fake
      with
      | exn ->
          let e = Exception.catch exn in
          if not error_recovery then
            raise
              (Parsing_error.Syntax_error
                 (TH.info_of_tok tr.Parsing_helpers.current));

          (if show_parsing_error then
             match exn with
             (* ocamlyacc *)
             | Parsing.Parse_error
             (* menhir *)
             | Parser_cpp.Error ->
                 LogLib.err (fun m ->
                     m "parse error \n = %s"
                       (error_msg_tok tr.Parsing_helpers.current))
             | Parsing_error.Other_error (s, _i) ->
                 LogLib.err (fun m ->
                     m "semantic error %s \n = %s" s
                       (error_msg_tok tr.Parsing_helpers.current))
             | _ -> Exception.reraise e);

          let line_error = TH.line_of_tok tr.Parsing_helpers.current in

          let pbline =
            tr.Parsing_helpers.passed
            |> List.filter (is_same_line_or_close line_error)
            |> List.filter TH.is_ident_like
          in
          let error_info =
            ( pbline
              |> List_.map (fun tok -> Tok.content_of_tok (TH.info_of_tok tok)),
              line_error )
          in
          stat.PS.problematic_lines <- error_info :: stat.PS.problematic_lines;

          (*  error recovery, go to next synchro point *)
          let passed', rest' =
            Parsing_recovery_cpp.find_next_synchro tr.Parsing_helpers.rest
              tr.Parsing_helpers.passed
          in
          tr.Parsing_helpers.rest <- rest';
          tr.Parsing_helpers.passed <- passed';

          tr.Parsing_helpers.current <-
            List_.hd_exn "can't be happening" passed';

          (* <> line_error *)
          let info = TH.info_of_tok tr.Parsing_helpers.current in
          let checkpoint2 = Tok.line_of_tok info in
          let checkpoint2_file = Tok.file_of_tok info in

          was_define := passed_a_define tr;
          if !was_define && !Flag_cpp.filter_define_error then ()
          else if
            (* bugfix: *)
            checkpoint_file =*= checkpoint2_file && checkpoint_file =*= file
          then
            Log.err (fun m ->
                m "%s"
                  (Parsing_helpers.show_parse_error_line line_error
                     (checkpoint, checkpoint2) filelines))
          else
            Log.err (fun m -> m "PB: bad: but on tokens not from original file");

          let info_of_bads =
            Common2.map_eff_rev TH.info_of_tok tr.Parsing_helpers.passed
          in

          Some (X (D (Ast.NotParsedCorrectly info_of_bads)))
    in

    (* again not sure if checkpoint2 corresponds to end of bad region *)
    let info = TH.info_of_tok tr.Parsing_helpers.current in
    let checkpoint2 = Tok.line_of_tok info in
    let checkpoint2_file = Tok.file_of_tok info in

    let diffline =
      if checkpoint_file =*= checkpoint2_file && checkpoint_file =*= file then
        checkpoint2 - checkpoint
      else 0
      (* TODO? so if error come in middle of something ? where the
       * start token was from original file but synchro found in body
       * of macro ? then can have wrong number of lines stat.
       * Maybe simpler just to look at tr.passed and count
       * the lines in the token from the correct file ?
       *)
    in
    let info = List.rev tr.Parsing_helpers.passed in

    (* some stat updates *)
    stat.PS.commentized <- stat.PS.commentized + count_lines_commentized info;
    (match elem with
    | Some (Ast.X (Ast.D (Ast.NotParsedCorrectly _xs))) ->
        (* todo: could count same line multiple times! use Hashtbl.add
         * and a simple Hashtbl.length at the end to add in error_line_count
         *)
        if !was_define && !Flag_cpp.filter_define_error then
          stat.PS.commentized <- stat.PS.commentized + diffline
        else stat.PS.error_line_count <- stat.PS.error_line_count + diffline
    | _ -> ());

    match elem with
    | None -> []
    | Some xs -> (xs, info) :: loop () (* recurse *)
  in
  let xs = loop () in
  let ast = xs |> List_.map fst in
  let tokens = xs |> List_.map snd |> List_.flatten in
  { Parsing_result.ast; tokens; stat }

let parse2 file : (Ast.program, T.token) Parsing_result.t =
  match File_type.file_type_of_file file with
  | FT.PL (FT.C _) -> (
      try parse_with_lang ~lang:Flag_cpp.C file with
      | _exn -> parse_with_lang ~lang:Flag_cpp.Cplusplus file)
  | FT.PL (FT.Cplusplus _) -> parse_with_lang ~lang:Flag_cpp.Cplusplus file
  | _ -> failwith (spf "not a C/C++ file: %s" !!file)

let parse file : (Ast.program, T.token) Parsing_result.t =
  Profiling.profile_code "Parse_cpp.parse" (fun () ->
      try parse2 file with
      | Stack_overflow ->
          Log.err (fun m -> m "Stack overflow in %s" !!file);
          {
            Parsing_result.ast = [];
            tokens = [];
            stat = { (PS.bad_stat !!file) with PS.have_timeout = true };
          })

let parse_program file =
  let res = parse file in
  res.Parsing_result.ast

(*****************************************************************************)
(* Sub parsers *)
(*****************************************************************************)

(* for sgrep/spatch *)
let any_of_string lang s =
  Common.save_excursion Flag_parsing.sgrep_mode true (fun () ->
      let toks_orig = tokens (Parsing_helpers.Str s) in

      let defs = create_defs lang in 

      let toks =
        try Parsing_hacks.fix_tokens ~macro_defs:defs lang toks_orig with
        | Token_views_cpp.UnclosedSymbol s ->
            Log.warn (fun m -> m "unclosed symbol %s" s);
            if !Flag_cpp.debug_cplusplus then
              raise (Token_views_cpp.UnclosedSymbol s)
            else toks_orig
      in

      let tr = Parsing_helpers.mk_tokens_state toks in
      let lexbuf_fake =
        Lexing.from_function (fun _buf _n -> raise Impossible)
      in

      (* -------------------------------------------------- *)
      (* Call parser *)
      (* -------------------------------------------------- *)
      Parser_cpp.semgrep_pattern (lexer_function tr) lexbuf_fake)
