# Description: 
### Functions to load and validate job configs
# Author: Daniel Sinderson
# Date: 2026-06-26



# IMPORTS =====================================================================
(import spork/json)
(import spork/schema)
(import spork/cron)
(import spork/path)



# MODULE LEVEL VARS ===========================================================




# FUNCTIONS ===================================================================
(defn- not-empty? [x] (not (empty? x)))

(defn- dash-key [k]
  (keyword (string/replace-all "_" "-" (string k))))

(defn- dash-top-keys [t]
  (tabseq [[k v] :pairs t] (dash-key k) v))



(defn job-defaults []
  @{:enabled true
    :max-retries 0
    :retry-backoff 5})

(def validate-job
  (schema/validator
      (props
        :name (and :string (pred not-empty?))
        :command (and :array (pred not-empty?) (values :string))
        :schedule (or :string :table)
        :enabled :boolean
        :max-retries (and :number (pred nat?))
        :retry-backoff (and :number (pred pos?))
        :timeout (or :nil (and :number (pred pos?)))
        :cwd (or :nil :string)
        :env (or :nil (and :table (values :string)))
        :alert-channel (or :nil :string)
        :alert-patterns (or :nil (and :array (values :string))))))


(defn validate-schedule
  ``Parse jobs schedule to make sure it's a valid cron expression,
  a valid literal argument like "@manual", or a valid struct detailing a specific trigger``
  [schedule]
  (cond
    (= schedule "@manual")
    schedule
    
    (string? schedule)
    (do (cron/parse-cron schedule) schedule)
    
    (and (table? schedule) (= (schedule :event) "file") (string? (schedule :path)))
    schedule
    
    (error (string/format "invalid schedule: %q" schedule))))


(defn load-job
  ``Read job from JSON, merge with default, validate its schema, then validate its schedule.
  Returns the job's table``
  [job-path]
  (def raw (dash-top-keys (json/decode (slurp job-path) true true)))
  (def job (merge (job-defaults) raw))
  (validate-job job)
  (validate-schedule (job :schedule))
  job)


(defn load-jobs-dir #### refactor later to find duplicated names and include in error message
  ``Load every job config in the jobs directory and parse as job.
  Throws an error if duplicate job names found``
  [dir]
  (def jobs @[])
  (each entry (sort (os/dir dir))
    (when (string/has-suffix? ".json" entry)
      (array/push jobs (load-job (path/join dir entry)))))
  (def names (map |($ :name) jobs))
  (unless (= (length names) (length (distinct names)))
    (error "duplicate job names in jobs directory"))
  jobs)


