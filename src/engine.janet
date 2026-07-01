# Description: 
### 
# Author: Daniel Sinderson
# Date: 2026-06-27



# IMPORTS =====================================================================
(import spork/tasker)
(import spork/path)
(import spork/sh)
(import ./util :as util)
(import ./triggers :as triggers)
(import ./alerts :as alerts)



# MODULE LEVEL VARS ===========================================================



# FUNCTIONS ===================================================================
(defn- backoff-seconds
  ``Exponential backoff with a cap for retries``
  [base attempt &opt max-backoff]
  (def capped (or max-backoff (* base 32)))
  (min capped (* base (math/pow 2 (dec attempt)))))


(defn- build-task-argv
  ``Bake the job's :cwd and :env into the argv that `tasker` will spawn``
  [job]
  (var argv (job :command))
  (when (job :cwd)
    (set argv ["sh" "-c" "cd \"$1\" && shift && exec \"$0\" \"$@\"" (argv 0) (job :cwd) ;(slice argv 1)]))
  (when (and (job :env) (not (empty? (job :env))))
    (def assignments (seq [[k v] :pairs (job :env)] (string k "=" v)))
    (set argv ["env" ;assignments ;argv]))
  argv)


(defn- attempt-failed?
  [result]
  (or (result :timed-out)
      (result :error)
      (and (result :exit-code) (not= 0 (result :exit-code)))))



## Log Consolidation
(defn- consolidate
  ``Captures taskers standard log outputs and pipes them into the user-defined log paths``
  [job config payload attempt max-attempts]
  (def name (job :name))
  (def started (or (payload :time-started) (util/now-unix)))
  (def pk (util/period-key (config :log-rotation) started))
  (def out-shared (path/join (config :stdout-log-dir) (string name "_" pk ".log")))
  (def err-shared (path/join (config :stderr-log-dir) (string name "_" pk ".log")))
  (def header (string/format "# --- attempt job=%s started=%s attempt=%d/%d ---"
                             name
                             (util/iso-timestamp started)
                             attempt
                             max-attempts))
  (def footer (string/format "# --- end status = %V exit=%V ---"
                             (payload :status)
                             (or (payload :return-code) "n/a")))
  
  (each [shared taskfile] [[out-shared (path/join (payload :dir) "out.log")]
                          [err-shared (path/join (payload :dir) "err.log")]]
    (util/append-line shared header)
    (when (os/stat taskfile)
      (def content (string/trimr (slurp taskfile)))
      (unless (empty? content) (util/append-line shared content)))
    (util/append-line shared footer))
  {:exit-code (payload :return-code)
   :timed-out (= (payload :status) :timeout)
   :error (payload :error)
   :log-stdout out-shared
   :log-stderr err-shared})



## 
(defn- update-state!
  ``Persist a job's run-state (last-run, counts) after a final outcome.``
  [config name outcome]
  (def state (util/read-jdn (config :state-file) @{}))
  (def prev (get state name @{:run-count 0 :fail-count 0}))
  (put state name @{:last-run (util/now-unix)
                    :last-status outcome
                    :run-count (inc (prev :run-count))
                    :fail-count (+ (prev :fail-count) (if (= outcome :failure) 1 0))})
  (util/write-jdn (config :state-file) state))


(defn- queue-job
  ``Enqueue one attempt of a job onto the tasker.
  The arguments for tasker/queue-task are [tasker argv &opt note priority qname timeout expiration input].
  We don't set a priority (so equals default of 4) or an expiration.``
  [tk job attempt max-attempts]
  (tasker/queue-task 
    tk 
    (build-task-argv job)
    (string "job=" (job :name))
    nil
    :default
    (job :timeout)
    nil
    @{:job-name (job :name)
      :attempt attempt
      :max-attempts max-attempts}))


## Hook functions
(defn- make-hooks
  ``Creates pre-task and post-task function hooks for a task.
  The pre-task function grabs the task input, name, and attempt counter and generates a log entry.
  The post-task does the same, then looks the job up in the registry, evaluates the result for an error mode, and conditionally branches based on it.
  If there's an error mode but still has retries, it computes the backoff for a retry and then schedules and queues it.
  Otherwise we log the results and, if an error mode, dispatch an alert.``

  [registry config]
  (def pre-task
    (fn [tk payload]
      (def i (payload :input))
      (util/log/info "engine"
                     "running job '%s' (attempt %d/%d)"
                     (i :job-name)
                     (i :attempt)
                     (i :max-attempts))))
  
  (def post-task
    (fn [tk payload]
      (def i (payload :input))
      (def name (i :job-name))
      (def attempt (i :attempt))
      (def max-attempts (i :max-attempts))
      (def entry (registry name))
      (when entry
        (def job (entry :spec))
        (def result (consolidate job config payload attempt max-attempts))
        (def fields (alerts/evaluate-attempt job result (config :alert-patterns)))
        (cond
          (and (attempt-failed? result) (< attempt max-attempts))
          (do
            (def backoff (backoff-seconds (job :retry-backoff) attempt))
            (util/log/warn "engine"
                           "job '%s' attempt %d/%d failed; retrying in %ds"
                           name
                           attempt
                           max-attempts
                           backoff)
            (ev/spawn (ev/sleep backoff) (queue-job tk job (inc attempt) max-attempts)))
          
          (do
            (def outcome (if (attempt-failed? result) :failure :success))
            (when fields (alerts/dispatch config fields))
            (update-state! config name outcome)
            (util/log/info "engine"
                           "job '%s' finished: %V"
                           name
                           outcome))))))
  [pre-task post-task])



(defn launch-job!
  ``Makes the job's trigger based on its config (manual, event, cron) then creates a fiber for the job to run on.
  If the job is enabled, it queues the job in tasker; if not, we write a log entry and skip.
  We then add the job to the registry.``
  [tk registry config job]
  (def trigger (triggers/make-trigger job))
  (def fiber
    (ev/go (fn [] (try (forever
      (ev/take (trigger :channel))
      (if (job :enabled)
        (queue-job tk job 1 (inc (job :max-retries)))
        (util/log/info "engine" "job '%s' fired but is disabled; skipping" (job :name))))
      ([_] nil)))))
  (put registry (job :name) @{:spec job :trigger trigger :fiber fiber}))



(defn start
  ``Starts the engine! Creates non-blocking tasker and executor pool, with one scheduler fiber per job.
  Returns @{:tasker :registry :config} for the control plane:
  :tasker contains information about the tasker,
  :registry holds information about the jobs being orchestrated by the tasker
  :config holds information about the global config settings that the tasker is running on``
  [config jobs]
  (util/log-init (config :daemon-log))
  (sh/create-dirs (config :home))
  (def tk (tasker/new-tasker (path/join (config :home) "tasks") [:default] 100))
  (def registry @{})
  (def [pre-task post-task] (make-hooks registry config))
  (tasker/spawn-executors tk nil (config :max-concurrent) pre-task post-task)
  (each job jobs (launch-job! tk registry config job))
  (util/log/info "engine"
                 "started: %d jobs, %d workers"
                 (length jobs)
                 (config :max-concurrent))
  @{:tasker tk :registry registry :config config})

