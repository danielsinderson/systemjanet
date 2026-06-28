# Description: 
### Functions to run jobs
# Author: Daniel Sinderson
# Date: 2026-06-27



# IMPORTS =====================================================================
(import spork/path)
(import ./util :as util)



# MODULE LEVEL VARS ===========================================================




# FUNCTIONS ===================================================================
(defn- build-argv
  ``Wrap argv so it runs inside cwd, if given.
  os/spawn has no cwd option, so we use a small sh shim that cd's first,
  then execs the real command.``
  [argv cwd]
  (if cwd
    ["sh" "-c" "cd \"$1\" && shift && exec \"$0\" \"$@\"" (argv 0) cwd ;(slice argv 1)]
    argv))


(defn- build-env
  ``Merge the job's :env on top of the daemon's environment.
  If the job set no env, it will return nil and inherit the parent environment``
  [job-env]
  (when (and job-env (not (empty? job-env)))
    (def string-keyed (tabseq [[k v] :pairs job-env] (string k) v))
    (merge (os/environ) string-keyed)))


(defn run-attempt #### REFACTOR THIS LATER; IT'S BEHEMOTH
  ``Run one attempt of a job. Capture stdout and stderr in two logs.
  Returns a result table with the following schema:
  {:exit-code int-or-nil :timed-out bool :error string-or-nil
   :started-at ts :ended-at ts :log-stdout path :log-stderr path}``
  [job config &opt attempt max-attempts]
  (default attempt 1)
  (default max-attempts 1)
  (def started-at (util/now-unix))
  (def pk (util/period-key (config :log-rotation) started-at))
  (def name (job :name))
  (def stdout-path (path/join (config :stdout-log-dir) (string name "_" pk ".log")))
  (def stderr-path (path/join (config :stderr-log-dir) (string name "_" pk ".log")))
  
  (def header (string/format "# --- attempt job=%s started=%s attempt=%d/%d ---"
    name
    (util/iso-timestamp started-at)
    attempt
    max-attempts))
  (util/append-line stdout-path header)
  (util/append-line stderr-path header)
  
  (def argv (build-argv (job :command) (job :cwd)))
  (def extra-env (build-env (job :env)))
  (def flags (if extra-env :ep :p))
  
  (def result
    (try
      (with [out (file/open stdout-path :a) file/close]
        (with [err (file/open stderr-path :a) file/close]
          (def opts (or extra-env @{}))
          (put opts :out out)
          (put opts :err err)
          (def proc (os/spawn argv flags opts))
          (def done (ev/chan 1))
          (ev/spawn (ev/give done (os/proc-wait proc)))
          (def timeout (job :timeout))
          (if timeout
            (do
              (def timer (ev/chan 1))
              (ev/spawn (ev/sleep timeout) (ev/give timer true))
              (def sel (ev/select done timer))
              (if (= (sel 1) timer)
                (do
                  (os/proc-kill proc)
                  (ev/take done) # reap the killed process to avoid zombie jobs
                  {:exit-code nil :timed-out true :error nil})
                {:exit-code (sel 2) :timed-out false :error nil}))
            {:exit-code (ev/take done) :timed-out false :error nil})))
        ([e] {:exit-code nil :timed-out false :error (string e)})))
  
  (def ended-at (util/now-unix))
  (def footer (string/format "# --- end exit=%V timed-out=%V duration=%ds ---"
    (or (result :exit-code) "n/a")
    (result :timed-out)
    (- ended-at started-at)))
  (util/append-line stdout-path footer)
  (util/append-line stderr-path footer)
  
  (merge result {:started-at started-at
                 :ended-at ended-at
                 :log-stdout stdout-path
                 :log-stderr stderr-path}))






