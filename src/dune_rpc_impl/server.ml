open! Stdune
open Fiber.O
open Dune_rpc_server
open Import
module Initialize = Dune_rpc.Initialize
module Public = Dune_rpc.Public
module Versioned = Dune_rpc.Versioned
module Server_notifications = Dune_rpc.Server_notifications
module Sub = Dune_rpc.Sub
module Progress = Dune_rpc.Progress
module Procedures = Dune_rpc.Procedures
module Id = Dune_rpc.Id
module Diagnostic = Dune_rpc.Diagnostic
module Conv = Dune_rpc.Conv
module Dep_conf = Dune_rules.Dep_conf
module Source_tree = Dune_engine.Source_tree
module Build_config = Dune_engine.Build_config
module Dune_project = Dune_engine.Dune_project
module Diff_promotion = Dune_engine.Diff_promotion
module Build_system = Dune_engine.Build_system
module Build_outcome = Decl.Build_outcome
module Status = Decl.Status

type pending_build_action =
  | Build of Dep_conf.t list * Build_outcome.t Fiber.Ivar.t

(* TODO un-copy-paste from dune/bin/arg.ml *)
let dep_parser =
  let open Dune_engine in
  Dune_lang.Syntax.set Stanza.syntax (Active Stanza.latest_version)
    Dep_conf.decode

module Client = struct
  type t = { mutable next_id : int }

  let create () = { next_id = 0 }

  let to_dyn { next_id = _ } =
    let open Dyn in
    opaque ()
end

module Session_comparable = Comparable.Make (struct
  type t = Client.t Session.t

  let compare = Session.compare

  let to_dyn s = Session.to_dyn Client.to_dyn s
end)

module Session_set = Session_comparable.Set

module Clients = struct
  type entry =
    { session : Client.t Session.Stage1.t
    ; mutable menu : Dune_rpc.Menu.t option
    }

  type t = entry Session.Id.Map.t

  let empty = Session.Id.Map.empty

  let add_session t (session : _ Session.Stage1.t) =
    let id = Session.Stage1.id session in
    let result = { menu = None; session } in
    Session.Stage1.register_upgrade_callback session (fun menu ->
        result.menu <- Some menu);
    Session.Id.Map.add_exn t id result

  let remove_session t (session : _ Session.t) =
    let id = Session.id session in
    Session.Id.Map.remove t id

  let to_list = Session.Id.Map.to_list

  let to_list_map = Session.Id.Map.to_list_map
end

(** Primitive unbounded FIFO channel. Reads are blocking. Writes are not
    blocking. At most one read is allowed at a time. *)
module Job_queue : sig
  type 'a t

  (** Remove the element from the internal queue without waiting for the next
      element. *)
  val pop_internal : 'a t -> 'a option

  val create : unit -> 'a t

  val read : 'a t -> 'a Fiber.t

  val write : 'a t -> 'a -> unit Fiber.t
end = struct
  (* invariant: if reader is Some then queue is empty *)
  type 'a t =
    { queue : 'a Queue.t
    ; mutable reader : 'a Fiber.Ivar.t option
    }

  let create () = { queue = Queue.create (); reader = None }

  let pop_internal t = Queue.pop t.queue

  let read t =
    Fiber.of_thunk (fun () ->
        match t.reader with
        | Some _ ->
          Code_error.raise "multiple concurrent reads of build job queue" []
        | None -> (
          match Queue.pop t.queue with
          | None ->
            let ivar = Fiber.Ivar.create () in
            t.reader <- Some ivar;
            Fiber.Ivar.read ivar
          | Some v -> Fiber.return v))

  let write t elem =
    Fiber.of_thunk (fun () ->
        match t.reader with
        | Some ivar ->
          t.reader <- None;
          Fiber.Ivar.fill ivar elem
        | None ->
          Queue.push t.queue elem;
          Fiber.return ())
end

type t =
  { config : Run.Config.t
  ; pending_build_jobs :
      (Dep_conf.t list * Build_outcome.t Fiber.Ivar.t) Job_queue.t
  ; pool : Fiber.Pool.t
  ; mutable clients : Clients.t
  }

let handler (t : t Fdecl.t) : 'a Dune_rpc_server.Handler.t =
  let on_init session (_ : Initialize.Request.t) =
    let t = Fdecl.get t in
    let client = Client.create () in
    t.clients <- Clients.add_session t.clients session;
    Fiber.return client
  in
  let on_terminate session =
    let t = Fdecl.get t in
    t.clients <- Clients.remove_session t.clients session;
    Fiber.return ()
  in
  let rpc =
    Handler.create ~on_terminate ~on_init
      ~version:Dune_rpc_private.Version.latest ()
  in
  let () =
    let module Diagnostic = Dune_rpc.Diagnostic in
    let module Error = Build_system.Error in
    let diff ~last ~(now : Error.Set.t) =
      match last with
      | None ->
        Error.Id.Map.to_list_map (Error.Set.current now) ~f:(fun _ e ->
            Diagnostic.Event.Add (Diagnostics.diagnostic_of_error e))
      | Some (prev : Error.Set.t) -> (
        match Error.Set.one_event_diff ~prev ~next:now with
        | Some last_event ->
          [ Diagnostics.diagnostic_event_of_error_event last_event ]
        | _ ->
          (* the slow path where we must calculate a diff between what we have
             and the last thing we've sent to the poller *)
          Error.Id.Map.merge (Error.Set.current prev) (Error.Set.current now)
            ~f:(fun _ prev now ->
              match (prev, now) with
              | None, None -> assert false
              | Some prev, None ->
                Some (Diagnostics.diagnostic_event_of_error_event (Remove prev))
              | _, Some next ->
                Some (Diagnostics.diagnostic_event_of_error_event (Add next)))
          |> Error.Id.Map.values)
    in
    Handler.implement_long_poll rpc Procedures.Poll.diagnostic
      Build_system.errors ~equal:Error.Set.equal ~diff
  in
  let () =
    let diff ~last:_ ~(now : Build_system.State.t) =
      match now with
      | Initializing -> Progress.Waiting
      | Restarting_current_build -> Interrupted
      | Build_succeeded__now_waiting_for_changes -> Success
      | Build_failed__now_waiting_for_changes -> Failed
      | Building now ->
        let remaining =
          now.number_of_rules_discovered - now.number_of_rules_executed
        in
        let complete = now.number_of_rules_executed in
        In_progress { complete; remaining }
    in
    Handler.implement_long_poll rpc Procedures.Poll.progress Build_system.state
      ~equal:Build_system.State.equal ~diff
  in
  let () =
    Handler.declare_notification rpc Procedures.Server_side.abort;
    Handler.declare_notification rpc Procedures.Server_side.log
  in
  let () =
    Handler.implement_request rpc Procedures.Public.ping (fun _ -> Fiber.return)
  in
  let () =
    let build _ targets =
      let ivar = Fiber.Ivar.create () in
      let targets =
        List.map targets ~f:(fun s ->
            Dune_lang.Decoder.parse dep_parser
              (Univ_map.set Univ_map.empty
                 Dune_engine.String_with_vars.decoding_env_key
                 (* CR-someday aalekseyev: hardcoding the version here is not
                    ideal, but it will do for now since this command is not
                    stable and we're only using it in tests. *)
                 (Dune_engine.Pform.Env.initial (3, 0)))
              (Dune_lang.Parser.parse_string ~fname:"dune rpc"
                 ~mode:Dune_lang.Parser.Mode.Single s))
      in
      let* () =
        Job_queue.write (Fdecl.get t).pending_build_jobs (targets, ivar)
      in
      Fiber.Ivar.read ivar
    in
    Handler.implement_request rpc Decl.build build
  in
  let () =
    let rec cancel_pending_jobs () =
      match Job_queue.pop_internal (Fdecl.get t).pending_build_jobs with
      | None -> Fiber.return ()
      | Some (_, job) ->
        let* () = Fiber.Ivar.fill job Build_outcome.Failure in
        cancel_pending_jobs ()
    in
    let shutdown _ () =
      let t = Fdecl.get t in
      let terminate_sessions () =
        Fiber.fork_and_join_unit cancel_pending_jobs (fun () ->
            Fiber.parallel_iter (Clients.to_list t.clients)
              ~f:(fun (_, entry) -> Session.Stage1.request_close entry.session))
      in
      let shutdown () =
        Fiber.fork_and_join_unit Dune_engine.Scheduler.shutdown Run.stop
      in
      Fiber.fork_and_join_unit terminate_sessions shutdown
    in
    Handler.implement_notification rpc Procedures.Public.shutdown shutdown
  in
  let () =
    let f _ () =
      let t = Fdecl.get t in
      let clients =
        Clients.to_list_map t.clients ~f:(fun _id (entry : Clients.entry) ->
            ( Initialize.Request.id (Session.Stage1.initialize entry.session)
            , match entry.menu with
              | None -> Status.Menu.Uninitialized
              | Some menu -> Menu (Dune_rpc.Menu.to_list menu) ))
      in
      Fiber.return { Status.clients }
    in
    Handler.implement_request rpc Decl.status f
  in
  let () =
    let f _ () =
      let errors = Fiber.Svar.read Dune_engine.Build_system.errors in
      Build_system.Error.Set.current errors
      |> Build_system.Error.Id.Map.values
      |> List.map ~f:Diagnostics.diagnostic_of_error
      |> Fiber.return
    in
    Handler.implement_request rpc Procedures.Public.diagnostics f
  in
  let source_path_of_string path =
    if Filename.is_relative path then Path.Source.(relative root path)
    else
      let source_root =
        Path.to_absolute_filename (Path.source Path.Source.root)
      in
      match String.drop_prefix path ~prefix:source_root with
      | None ->
        User_error.raise [ Pp.textf "path isn't available in workspace" ]
      | Some s ->
        let s = String.drop_prefix_if_exists s ~prefix:"/" in
        Path.Source.(relative root s)
  in
  let () =
    let f _ (path, `Contents contents) =
      let+ version =
        Memo.run
          (let open Memo.O in
          let source_path = source_path_of_string path in
          let+ dir = Source_tree.nearest_dir source_path in
          let project = Source_tree.Dir.project dir in
          Dune_project.dune_version project)
      in
      let module Format_dune_lang = Dune_engine.Format_dune_lang in
      Format_dune_lang.format_string ~version contents
    in
    Handler.implement_request rpc Procedures.Public.format_dune_file f
  in
  let () =
    let f _ path =
      let files = source_path_of_string path in
      Diff_promotion.promote_files_registered_in_last_run
        (These ([ files ], ignore));
      Fiber.return ()
    in
    Handler.implement_request rpc Procedures.Public.promote f
  in
  let () =
    let f _ () = Fiber.return Path.Build.(to_string root) in
    Handler.implement_request rpc Procedures.Public.build_dir f
  in
  rpc

let create ~root =
  let t = Fdecl.create Dyn.opaque in
  let pending_build_jobs = Job_queue.create () in
  let handler = Dune_rpc_server.make (handler t) in
  let pool = Fiber.Pool.create () in
  let config = Run.Config.Server { handler; backlog = 10; pool; root } in
  let res = { config; pending_build_jobs; clients = Clients.empty; pool } in
  Fdecl.set t res;
  res

let config t = t.config

let pending_build_action t =
  Job_queue.read t.pending_build_jobs
  |> Fiber.map ~f:(fun (targets, ivar) -> Build (targets, ivar))
