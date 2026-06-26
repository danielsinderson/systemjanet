# Description: 
### Helper functions used throughout the systemjanet project:
### timestamps, log-file rotation keys, JDN persistence, and
### the systemjanet daemon's own logger
# Author: Daniel Sinderson
# Date: 2026-06-24



# IMPORTS =====================================================================
(import spork/path)
(import spork/sh)



# MODULE LEVEL VARS ===========================================================
(var- log-path nil)
(var- log-echo true)



# FUNCTIONS ===================================================================
## TIME STAMPS UTILITIES ======================================================
(defn now-unix [] (os/time))

(defn iso-timestamp
  ``Format unix timestamp into something for us humans to read``
  [&opt t]
  (def d (os/date (or t (now-unix)) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02d"
    (d :year) (inc (d :month)) (inc (d :month-day))
    (d :hours) (d :minutes) (d :seconds)))

(defn filename-timestamp
  ``Timestamp without colons for use in filenames``
  [&opt t]
  (def d (os/date (or t (now-unix)) true))
  (string/format "%04d-%02d-%02dT%02d%02d%02d"
    (d :year) (inc (d :month)) (inc (d :month-day))
    (d :hours) (d :minutes) (d :seconds)))

(defn period-key
  ``Timestamp formatted to given period: daily, weekly, monthly``
  [period &opt t]
  (def d (os/date (or t (now-unix)) true))
  (case period
    :daily (string/format "%04d-%02d-%02d" (d :year) (inc (d :month)) (inc (d :month-day)))
    :weekly (string/format "%04d-W%02d" (d :year) (inc (div (d :year-day) 7)))
    :monthly (string/format "%04d-%02d" (d :year) (inc (d :month)))
    :quarterly (string/format "%04d-Q%01d" (d :year) (inc (div (d :month) 3)))
    :yearly (string/format "%04d" (d :year))
    (error (string/format "undefined period: %q" period))))



## ORCHESTRATOR DATA PERSISTENCE ==============================================
(defn write-jdn
  ``Persist a data structure to disk for later use; tmp then os/rename used for crash-safe writes``
  [target data]
  (sh/create-dirs-to target)
  (def tmp (string target ".tmp"))
  (spit tmp (string/format "%q" data))
  (os/rename tmp target))

(defn read-jdn
  ``Read back persisted data structure from JDN file``
  [target &opt default-value]
  (if (os/stat target)
    (try 
      (parse (slurp target))
      ([_] default-value))
    default-value))



## LOGGING UTILITIES ==========================================================
(defn append-line
  ``Append a line of text to a file, spawning directory and file if missing``
  [target line]
  (sh/create-dirs-to target)
  (def f (file/open target :a))
  (when f
    (file/write f line)
    (file/write f "\n")
    (file/close f)))

(defn log-init
  ``Configure logging defaults for location and echo behavior``
  [target &opt echo?]
  (set log-path target)
  (set log-echo (not= echo? false))
  (sh/create-dirs-to target))

(defn log
  ``Write a line to the log.
  `level` is the severity level, `tag` is a short component name string,
  `fmt` is a format string, and `args` is a variadic catchall``
  [level tag fmt & args]
  (def msg (string/format ;(array/push @[fmt] ;args)))
  (def line (string/format "%s %-5s [%s] %s"
    (iso-timestamp)
    (string/ascii-upper (string level))
    tag
    msg))
  (when log-path (append-line log-path line))
  (when log-echo (print line)))

(defn log/info [tag fmt & args] (log :info tag fmt ;args))
(defn log/warn [tag fmt & args] (log :warn tag fmt ;args))
(defn log/error [tag fmt & args] (log :error tag fmt ;args))

