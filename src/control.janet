# Description: 
### 
# Author: Daniel Sinderson
# Date: 2026-06-30



# IMPORTS =====================================================================
(import spork/rpc)
(import spork/tasker)
(import ./util :as util)
(import ./jobspec :as jobspec)
(import ./engine :as engine)



# MODULE LEVEL VARS ===========================================================



# FUNCTIONS ===================================================================

## Functions to build the status report
(defn- schedule-desc
  ``Describe the schedule``
  [schedule]
  (cond
    (= schedule "@manual") "manual"
    (string? schedule) schedule
    (table? schedule) (string "event:" (schedule :path))
    "?"))


(defn- snapshot
  ``Build a plain-data status report per job from the live registry and persisted file state.``
  [sys]
  (def config (sys :config))
  (def registry (sys :registry))
  (def state (util/read-jdn (config :state-file) @{}))
  (seq [name :in (sort (keys registry))]
    (def entry (registry name))
    (def job (entry :spec))
    (def st (get state name @{}))
    @{:name name
      :enabled (job :enabled)
      :schedule (schedule-desc (job :schedule))
      :last-run (if (st :last-run) (util/iso-timestamp (st :last-run)) "never")
      :last-status (string (or (st :last-status) "-"))
      :run-count (get st :run-count 0)
      :fail-count (get st :fail-count 0)}))



## Functions to reload and reconcile the registry
(defn- stop-job!
  [registry name]
  (def entry (registry name))
  (when entry
    ((get-in entry [:trigger :stop]))
    (try (ev/cancel (entry :fiber) "reload") ([_] nil))
    (put registry name nil)))


(defn- reload!
  [sys jobs-dir]
  (def registry (sys :registry))
  (def jobs (jobspec/load-jobs-dir jobs-dir))
  (def new-names (map |($ :name) jobs))
  (each name (keys registry)
    (unless (index-of name new-names) (stop-job! registry name)))
  (each job jobs
    (when (registry (job :name)) (stop-job! registry (job :name)))
    (engine/launch-job! (sys :tasker) registry (sys :config) job))
  (string "reloaded " (length jobs) " jobs"))



(defn- trigger-job
  [sys name]
  (def entry ((sys :registry) name))
  (if entry
    (do ((get-in entry [:trigger :fire])) (string "triggered " name))
    (string "unknown job: " name)))



## The RPC server
(defn server
  ``Start the control-socket RPC server on config's :control-sock.
  Exposes ping/status/trigger/reload/stop.
  Returns the server stream.``
  [sys jobs-dir]
  (def config (sys :config))
  (def sockpath (config :control-sock))
  (when (os/stat sockpath) (os/rm sockpath))
  (def funcs
    @{"ping" (fn [self] "pong")
      "status" (fn [self] (snapshot sys))
      "trigger" (fn [self name] (trigger-job sys name))
      "reload" (fn [self] (reload! sys jobs-dir))
      "stop" (fn [self]
                (tasker/close-queues (sys :tasker))
                (ev/spawn (ev/sleep 0.2) (os/exit 0))
                "stopping")})
  (util/log/info "control" "listening on %s" sockpath)
  (rpc/server funcs :unix sockpath))


