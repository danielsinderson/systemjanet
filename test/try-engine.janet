(import ../src/engine :as engine)

(os/mkdir "./tmp/sj-demo")
(spit "./tmp/sj-demo/hook.sh"
      "#!/bin/sh\necho \"ALERT job=$SYSTEMJANET_JOB reason=$SYSTEMJANET_REASON\" >> ./tmp/sj-demo/alerts-fired.txt\n")
(os/chmod "./tmp/sj-demo/hook.sh" 8r755)

(def config
  @{:home "./tmp/sj-demo/home"
    :stdout-log-dir "./tmp/sj-demo/out" :stderr-log-dir "./tmp/sj-demo/err"
    :log-rotation :daily :max-concurrent 2
    :daemon-log "./tmp/sj-demo/daemon.log" :alerts-log "./tmp/sj-demo/alerts.log"
    :state-file "./tmp/sj-demo/state.jdn"
    :alert-patterns @["error" "fatal"]
    :default-alert-channel "shell"
    :alert-channels @{:shell @{:command ["sh" "./tmp/sj-demo/hook.sh"]}}})

(def jobs
  @[@{:name "greet" :command ["sh" "-c" "echo hi-from-greet"] :schedule "@manual"
     :enabled true :max-retries 0 :retry-backoff 1}
    @{:name "flaky" :command ["sh" "-c" "echo trying 1>&2; exit 3"] :schedule "@manual"
     :enabled true :max-retries 2 :retry-backoff 1}
    @{:name "ctx" :command ["sh" "-c" "pwd; echo dest=$DEST"] :schedule "@manual"
     :enabled true :max-retries 0 :retry-backoff 1 :cwd "./tmp" :env @{:DEST "xyz"}}])

(def sys (engine/start config jobs))
(def reg (sys :registry))
((get-in reg ["greet" :trigger :fire]))
((get-in reg ["ctx" :trigger :fire]))
((get-in reg ["flaky" :trigger :fire]))
(ev/sleep 6)   # let flaky exhaust its retries (backoff 1s, 2s)
(print "\n=== greet stdout ===")     (print (slurp (first (os/dir "./tmp/sj-demo/out"))))
(os/exit 0)


