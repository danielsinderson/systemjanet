(declare-project
  :name "systemjanet"
  :description "A job orchestration daemon modeled after systemd, written in Janet."
  :author "drsinderson"
  :license "MIT"
  :version "0.1.0"
  :dependencies ["https://github.com/janet-lang/spork.git"])

(declare-source
  :source @["src"])

(declare-binscript
  :main "systemjanet"
  :hardcode-syspath true
  :is-janet true)
