# Description: 
### 
# Author: Daniel Sinderson
# Date: 2026-06-25



# IMPORTS =====================================================================
(import spork/json)
(import spork/schema)



# MODULE LEVEL VARS ===========================================================



# FUNCTIONS ===================================================================
## DEFAULT CONFIG GENERATOR AND CONFIG VALIDATOR FUNCTIONS ====================
(defn default-config []
  ``Returns the default system configuration``
  @{:home "~/.systemjanet"
    :stdout-log-dir "~/.systemjanet/logs/stdout"
    :stderr-log-dir "~/.systemjanet/logs/stderr"
    :log-rotation "daily"
    :max-concurrent 4
    :daemon-log "~/.systemjanet/daemon.log"
    :alerts-log "~/.systemjanet/alerts.log"
    :control-sock "~/.systemjanet/control.sock"
    :state-file "~/.systemjanet/state.jdn"
    :alert-channels @{}
    :alert-patterns @["error" "exception" "traceback" "panic" "fatal" "segmentation fault"]})

(def validate-config
  (schema/validator
    (props
      :home :string
      :stdout-log-dir :string
      :stderr-log-dir :string
      :log-rotation (enum "daily" "weekly" "monthly" "quarterly" "yearly")
      :max-concurrent (and :number (pred pos?))
      :daemon-log :string
      :alerts-log :string
      :control-sock :string
      :state-file :string
      :alert-channels (and :table (values (props :command :array :description (or :nil :string))))
      :default-alert-channel (or :nil :string)
      :alert-patterns (and :array (values :string)))))


## FUNCTIONS FOR NORMALIZING JSON TO JANET TABLE ==============================
(defn- dash-key [k]
  (keyword (string/replace-all "_" "-" (string k))))

(defn- dash-top-keys [t]
  (tabseq [[k v] :pairs t] (dash-key k) v))

(def- path-keys
  [:home :stdout-log-dir :stderr-log-dir :daemon-log :alerts-log :control-sock :state-file])

(defn- expand-tilde [p]
  (if (string/has-prefix? "~" p)
    (string (os/getenv "HOME") (slice p 1)) p))

(defn- normalize [config]
  (each k path-keys
    (put config k (expand-tilde (config k))))
  (put config :log-rotation (keyword (config :log-rotation)))
  config)


## PUBLIC FUNCTION FOR ACTUALLY LOADING THE CONFIG ============================
(defn load-config
  ``Load and validate the project config.json, potentially from a user-specified path after checking that the file exists there.
  Merge it with the default config to set any unspecified values to defaults.
  Validate it against the schema.
  Process it to transform "_" -> "-", expand "~" to path values, and convert log rotation to a keyword.
  Then return a ready-to-use config table.``
  [&opt config-path]
  (def user-config
    (if (and config-path (os/stat config-path))
      (dash-top-keys (json/decode (slurp config-path) true true))
      @{}))
  (def merged-config (merge (default-config) user-config))
  (validate-config merged-config)
  (normalize merged-config))

