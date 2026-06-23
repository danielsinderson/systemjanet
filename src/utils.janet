(defn now-unix [] (os/time))


(defn iso-timestamp
  ``Render a unix timestamp (default is "now") as a sortable, human-readable string.``
  [&opt t]
  (def d (os/date (or t (now-unix)) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02d"
    (d :year) (inc (d :month)) (inc (d :month-day)) # increments necessary for fields represented by 0-index
    (d :hours) (d :minutes) (d :seconds)))


(defn filename-timestamp
  ``ISO timestamp without colons so its safe in filenames``
  [&opt t]
  (def d (os/date (or t (now-unix)) true))
  (string/format "%04d-%02d-%02dT%02d%02d%02d"
    (d :year) (inc (d :month)) (inc (d :month-day)) # increments necessary for fields represented by 0-index
    (d :hours) (d :minutes) (d :seconds)))


(defn ensure-dir
  ``Recursive directory creation, ignoring directories in the tree that already exist``
  [path]
  (var built "")
  (each part (string/split "/" path)
    (cond
      (empty? part) (when (empty? built) (set built "/")) # treats the empty beginning to ensure absolute paths stay absolute
      (empty? built) (set built part)
      (= built "/") (set built (string built part))
      (set built (string built "/" part)))
    (unless (empty? built)
      (try (os/mkdir built) ([_] nil))))
  path)


(defn dirname
  ``Return the directory part of a path``
  [path]
  (def parts (string/split "/" path))
  (string/join (slice parts 0 (max 0 (- (length parts) 1))) "/"))


(defn join-path
  ``Join path components with "/", ignoring empty pieces.``
  [& parts]
  (string/join (filter (fn [p] (not (empty? p))) parts) "/"))
