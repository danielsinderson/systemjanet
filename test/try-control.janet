(import ./src/engine :as engine)
(import ./src/control :as control)
(import ./src/client :as client)
(import ./src/jobspec :as jobspec)
(import spork/sh)

(sh/rm "./tmp/sj-ctl")                          # clean slate (avoid Phase 7's stale-task replay)
(os/mkdir "./tmp/sj-ctl")
(os/mkdir "./tmp/sj-ctl/jobs")
(spit "./tmp/sj-ctl/jobs/greet.json"
      `{"name":"greet","command":["echo","hi"],"schedule":"@manual","enabled":true}`)

(def config
  @{:home "./tmp/sj-ctl/home" :stdout-log-dir "./tmp/sj-ctl/out" :stderr-log-dir "./tmp/sj-ctl/err"
    :log-rotation :daily :max-concurrent 2 :daemon-log "./tmp/sj-ctl/daemon.log"
    :alerts-log "./tmp/sj-ctl/alerts.log" :state-file "./tmp/sj-ctl/state.jdn"
    :control-sock "./tmp/sj-ctl/control.sock"
    :alert-patterns @[] :default-alert-channel nil :alert-channels @{}})

(def sys (engine/start config (jobspec/load-jobs-dir "./tmp/sj-ctl/jobs")))
(control/server sys "./tmp/sj-ctl/jobs")
(ev/sleep 0.3)                                 # let the socket come up

(def sock "./tmp/sj-ctl/control.sock")
(print "ping    => " (client/call sock "ping"))
(print "trigger => " (client/call sock "trigger" "greet"))
(ev/sleep 0.4)
(print "status:")
(each row (client/call sock "status")
  (printf "  %-8s runs=%d fails=%d last=%s"
          (row :name) (row :run-count) (row :fail-count) (row :last-status)))
(spit "./tmp/sj-ctl/jobs/late.json"
      `{"name":"late","command":["true"],"schedule":"@manual","enabled":true}`)
(print "reload  => " (client/call sock "reload"))
(print "jobs now: " (string/format "%q" (sort (map |($ :name) (client/call sock "status")))))
(print "bad name=> " (client/call sock "trigger" "nope"))
(os/exit 0)