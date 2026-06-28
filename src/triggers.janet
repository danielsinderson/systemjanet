# Description: 
### Functions to trigger jobs and processes
# Author: Daniel Sinderson
# Date: 2026-06-27



# IMPORTS =====================================================================
(import spork/cron)
(import ./util :as util)



# MODULE LEVEL VARS ===========================================================
(def- default-poll-interval 5)



# FUNCTIONS ===================================================================
(defn- cron-trigger
  ``Loops forever, sleeping until the next cron trigger at which point it creates a channel.
  Exits quietly when its fiber is cancelled by :stop.``
  [schedule channel]
  (def parsed (cron/parse-cron schedule))
  (try
    (forever
      (def now (util/now-unix))
      (def next-ts (cron/next-timestamp parsed now))
      (ev/sleep (max 0 (- next-ts now)))
      (ev/give channel true))
    ([_] nil)))


(defn- event-trigger
  ``Loops forever, polling the watched file each interval for its mtime.
  Fires a channel if mtime changed.
  Exits quietly when its fiber is cancelled by :stop.``
  [schedule channel interval]
  (def watched (schedule :path))
  (var last-mtime (when-let [s (os/stat watched)] (s :modified)))
  (try
    (forever
      (ev/sleep interval)
      (def s (os/stat watched))
      (def mtime (when s( s :modified)))
      (unless (= mtime last-mtime)
        (set last-mtime mtime)
        (ev/give channel true)))
    ([_] nil)))


(defn make-trigger
  ``Create fire channels per job and start its automatic trigger source based on the job's schedule.
  Returns a table @{:channel :fire (fn []) :stop (fn [])}``
  [job &opt poll-interval]
  (default poll-interval default-poll-interval)
  (def channel (ev/chan 1))
  (def schedule (job :schedule))
  (def fibers @[])
  (cond
    (= schedule "@manual")
    nil
    
    (string? schedule)
    (array/push fibers (ev/go (fn [] (cron-trigger schedule channel))))
    
    (table? schedule)
    (array/push fibers (ev/go (fn [] (event-trigger schedule channel poll-interval)))))
  @{:channel channel
    :fire (fn [] (ev/spawn (ev/give channel true)))
    :stop (fn [] (each f fibers (ev/cancel f "stopped")))})

