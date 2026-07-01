# Description: 
### 
# Author: Daniel Sinderson
# Date: 2026-07-01



# IMPORTS =====================================================================
(import ./src/engine :as engine)
(import ./src/control :as control)
(import ./src/jobspec :as jobspec)
(import spork/sh)

(sh/rm "/tmp/sj-ctl2")
(os/mkdir "/tmp/sj-ctl2")
(os/mkdir "/tmp/sj-ctl2/jobs")

(def config @{:home "/tmp/sj-ctl2/home" :stdout-log-dir "/tmp/sj-ctl2/out"
              :stderr-log-dir "/tmp/sj-ctl2/err" :log-rotation :daily :max-concurrent 2
              :daemon-log "/tmp/sj-ctl2/daemon.log" :alerts-log "/tmp/sj-ctl2/alerts.log"
              :state-file "/tmp/sj-ctl2/state.jdn" :control-sock "/tmp/sj-ctl2/control.sock"
              :alert-patterns @[] :default-alert-channel nil :alert-channels @{}})

(def sys (engine/start config (jobspec/load-jobs-dir "/tmp/sj-ctl2/jobs")))
(control/server sys "/tmp/sj-ctl2/jobs")
(forever (ev/sleep 3600))




# MODULE LEVEL VARS ===========================================================



# FUNCTIONS ===================================================================