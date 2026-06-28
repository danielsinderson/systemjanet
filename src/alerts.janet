# Description: 
### Functions parse job attempt results to assess errors,
### and if any are found write them to the log and raise an alert
# Author: Daniel Sinderson
# Date: 2026-06-27



# IMPORTS =====================================================================
(import ./util :as util)



# MODULE LEVEL VARS ===========================================================




# FUNCTIONS ===================================================================
## Functions for scanning logs and evaluating job results =====================
(defn scan-text
  ``Return the list of patterns in the text (case-insensitive)``
  [text patterns]
  (def lower (string/ascii-lower text))
  (seq [p :in patterns :when (string/find (string/ascii-lower p) lower)]
  p))

### refactor later to first pull only those parts of the log that are new since the last scan
(defn- scan-log-file
  [path patterns]
  (if (and path (os/stat path))
  (scan-text (slurp path) patterns)
  []))


(defn evaluate-attempt
  ``Decide whether a finished attempt deserves an alert.
  If the attempt timed out, had an error, had an exit code that is neither nil or 0, or if one of the patterns matched on the output it returns an alert table.
  If none of those things hit, it returns nil.
  @{:job :alert-channel :log-stdout :log-stderr :reason :exit-code}``
  [job result global-patterns]
  (def base @{:job (job :name)
              :alert-channel (job :alert-channel)
              :log-stdout (result :log-stdout)
              :log-stderr (result :log-stderr)})
  (cond
    (result :timed-out)
    (merge base {:reason "timed out"
                 :exit-code nil})
    
    (result :error)
    (merge base {:reason (string "could not run: " (result :error))
                 :exit-code nil})
    
    (and (result :exit-code) (not= 0 (result :exit-code)))
    (merge base {:reason (string/format "exited with code %d" (result :exit-code))
                 :exit-code (result :exit-code)})
    
    (let [patterns (or (job :alert-patterns) global-patterns)
          hits (distinct [;(scan-log-file (result :log-stdout) patterns)
                          ;(scan-log-file (result :log-stderr) patterns)])]
      (if (empty? hits)
        nil
        (merge base {:reason (string/format "matched patterns(s): %s" (string/join hits ", "))
                     :exit-code (result :exit-code)})))))



## Functions for delivering alerts ============================================
(defn- hook-env
  ``Stringify hook environment``
  [fields]
  @{"SYSTEMJANET_JOB" (string (fields :job))
    "SYSTEMJANET_REASON" (string (fields :reason))
    "SYSTEMJANET_EXIT_CODE" (string (or (fields :exit-code) ""))
    "SYSTEMJANET_LOG_STDOUT" (string (or (fields :log-stdout) ""))
    "SYSTEMJANET_STDERR" (string (or (fields :log-stderr) ""))})


(defn- run-hook
  ``Fire and forget a hook command with alert details in env variables.
  Reaps the process in the background without blocking caller``
  [hook-argv fields]
  (try # stops broken hook command from taking down alerter
    (do
      (def env (merge (os/environ) (hook-env fields)))
      (def proc (os/spawn hook-argv :ep env))
      (ev/spawn (try (os/proc-wait proc) ([_] nil)))) # this `try` stops wait errors from bubbling up in stack trace and crashing the program
    ([err] (util/log/error "alert" "alert hook failed: %V" err))))


(defn dispatch
  ``Record and deliver an alert.
  Appends a line to the alerts log then resolves the alert channel and fires hook command if present``
  [config fields]
  (def line (string/format "%s job=%V reason=%V exit-code=%V"
                           (util/iso-timestamp)
                           (fields :job)
                           (fields :reason)
                           (fields :exit-code)))
  (util/append-line (config :alerts-log) line)
  (util/log/warn "alert" "%s" line)
  (def channel-name (or (fields :alert-channel) (config :default-alert-channel)))
  (when channel-name
    (def channel (get (config :alert-channels) (keyword channel-name)))
    (if channel
      (run-hook (channel :command) fields)
      (util/log/warn "alert" "unknown alert channel %V" channel-name))))



