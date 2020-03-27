(* This file is part of Lwt, released under the MIT license. See LICENSE.md for
   details, or visit https://github.com/ocsigen/lwt/blob/master/LICENSE.md. *)



(* [Lwt_sequence] is deprecated – we don't want users outside Lwt using it.
   However, it is still used internally by Lwt. So, briefly disable warning 3
   ("deprecated"), and create a local, non-deprecated alias for
   [Lwt_sequence] that can be referred to by the rest of the code in this
   module without triggering any more warnings. *)
[@@@ocaml.warning "-3"]
module Lwt_sequence = Lwt_sequence
[@@@ocaml.warning "+3"]

open Lwt.Infix

(* +-----------------------------------------------------------------+
   | Parameters                                                      |
   +-----------------------------------------------------------------+ *)

(* Minimum number of domains: *)
let min_channels : int ref = ref 0
(* Maximum number of domains: *)
let max_channels : int ref = ref 0

(* Size of the waiting queue: *)
let max_channel_queued = ref 1000

let get_max_number_of_domains_queued _ =
  !max_channel_queued

let set_max_number_of_domains_queued n =
  if n < 0 then invalid_arg "Lwt_preemptive.set_max_number_of_domains_queued";
  max_channel_queued := n

(* The total number of domains currently running: *)
let channels_count = ref 0

  module C = Domainslib.Chan 


type message = Do of (unit -> unit) | Quit 

type chan = {
  req : message C.t;
  resp : unit C.t;
}

(* Pool of worker channels: *)
let channels : chan Queue.t = Queue.create ()

(* Queue of clients waiting for a worker to be available: *)
let waiters : chan Lwt.u Lwt_sequence.t = Lwt_sequence.create ()

(* Code executed by a channel: *)
let rec worker_loop channel =
  match C.recv channel.req with
  | Do f -> f (); C.send channel.resp (); worker_loop channel ()
  | Quit -> ()

(* create a new channel: *)
let make_channel_and_domain () =
  incr channels_count;
  let channel = {
    req : C.make 1;
    resp : C.make 1;
  } in
  let domain = Domain.spawn (fun () -> worker_loop channel) in
  (* added domain to pass it as a tuple
    need make sure the output is consistent wherever this function is used 
    this is different from previous behaviour *)
  (channel, domain)
(* Add a channel to the pool: *)
let add_channel channel =
  match Lwt_sequence.take_opt_l waiters with
  | None ->
    Queue.add channel channels
  | Some w ->
    C.send channel.req Quit

(* Wait for channel to be available, then return it: *)
let get_channel () =
  if not (Queue.is_empty channel) then
    Lwt.return (Queue.take channel)
  else if !channels_count < !max_channels then
    Lwt.return (make_worker ())
  else
    (Lwt.add_task_r [@ocaml.warning "-3"]) waiters

(* +-----------------------------------------------------------------+
   | Initialisation, and dynamic parameters reset                    |
   +-----------------------------------------------------------------+ *)

let get_bounds () = (!min_channels, !max_channels)

let set_bounds (min, max) =
  if min < 0 || max < min then invalid_arg "Lwt_preemptive.set_bounds";
  let diff = min - !channels_count in
  min_channels := min;
  max_channels := max;
  (* Launch new workers: *)
  for _i = 1 to diff do
    add_channel (make_channel ())
  done

let initialized = ref false

let init min max _errlog =
  initialized := true;
  set_bounds (min, max)

let simple_init () =
  if not !initialized then begin
    initialized := true;
    set_bounds (0, 4)
  end

let nbchannels () = !channels_count
let nbchannelsqueued () = Lwt_sequence.fold_l (fun _ x -> x + 1) waiters 0
let nbchannelsbusy () = !channels_count - Queue.length channels

(* +-----------------------------------------------------------------+
   | Detaching                                                       |
   +-----------------------------------------------------------------+ *)

let init_result = Result.Error (Failure "Lwt_preemptive.detach")

let detach f args =
  simple_init ();
  let result = ref init_result in
  (* The task for the worker thread: *)
  let task () =
    try
      result := Result.Ok (f args)
    with exn ->
      result := Result.Error exn
  in
  get_channels () >>= fun channel ->
  let waiter, wakener = Lwt.wait () in
  let id =
    Lwt_unix.make_notification ~once:true
      (fun () -> Lwt.wakeup_result wakener !result)
  in
  Lwt.finalize
    (fun () ->
       (* Send the task to the channel: *)
       C.send channel.req (Do task))
    (fun () ->
       if C.recv channel.resp = ()
         (* Put back the worker to the pool: *)
         add_worker channel
       else begin
         decr channels_count;
         (* Or wait for the thread to terminates, to free its associated
            resources: *)
         Domain.join worker.domain
       end;
       Lwt.return_unit)

(* +-----------------------------------------------------------------+
   | Running Lwt threads in the main thread                          |
   +-----------------------------------------------------------------+ *)

(* Queue of [unit -> unit Lwt.t] functions. *)
let jobs = Queue.create ()

(* Mutex to protect access to [jobs]. *)
let jobs_mutex = Mutex.create ()

let job_notification =
  Lwt_unix.make_notification
    (fun () ->
       (* Take the first job. The queue is never empty at this
          point. *)
       Mutex.lock jobs_mutex;
       let thunk = Queue.take jobs in
       Mutex.unlock jobs_mutex;
       ignore (thunk ()))

(* There is a potential performance issue from creating a cell every time this
   function is called. See:
   https://github.com/ocsigen/lwt/issues/218
   https://github.com/ocsigen/lwt/pull/219
   http://caml.inria.fr/mantis/view.php?id=7158 *)
let run_in_main f =
  let cell = CELL.make () in
  (* Create the job. *)
  let job () =
    (* Execute [f] and wait for its result. *)
    Lwt.try_bind f
      (fun ret -> Lwt.return (Result.Ok ret))
      (fun exn -> Lwt.return (Result.Error exn)) >>= fun result ->
    (* Send the result. *)
    CELL.set cell result;
    Lwt.return_unit
  in
  (* Add the job to the queue. *)
  Mutex.lock jobs_mutex;
  Queue.add job jobs;
  Mutex.unlock jobs_mutex;
  (* Notify the main thread. *)
  Lwt_unix.send_notification job_notification;
  (* Wait for the result. *)
  match CELL.get cell with
  | Result.Ok ret -> ret
  | Result.Error exn -> raise exn
