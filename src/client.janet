# Description: 
### 
# Author: Daniel Sinderson
# Date: 2026-07-01



# IMPORTS =====================================================================
(import spork/rpc)




# MODULE LEVEL VARS ===========================================================



# FUNCTIONS ===================================================================
## Functions for talking to a running daemon's control socket via RPC
## and calling methods

(defn connect
  ``Connects to a running daemon's control socket.
  Returns an RPC client.
  Used for calling methods like (:status c), (:trigger c "name"), or (:close c).``
  [socketpath]
  (rpc/client :unix socketpath "systemjanet-cli"))


(defn call
  ``One-shot call; connects to socket, invokes a method with args,
  closes the connection, and returns the result.``
  [socketpath method & args]
  (def connection
    (try (connect socketpath)
      ([_] (error (string "could not connect to " socketpath " -- is systemjanet running?")))))
  (defer (:close connection)
    (def func (get connection (keyword method)))
    (unless func (error (string "unknown control method: " method)))
    (func connection ;args)))





