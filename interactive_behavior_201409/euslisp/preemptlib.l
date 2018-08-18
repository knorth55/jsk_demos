#!/usr/bin/env roseus
;; preemptlib.l
;; Author: furushchev <furushchev@jsk.imi.i.u-tokyo.ac.jp>

(provide :preemptlib)

;; imports
(require :eus-pddl-client "package://pddl_planner/src/eus-pddl-client.l")
(require :pddl-result-graph "package://pddl_planner/src/pddl-result-graph.l")
(require :pddl2smach "package://roseus_smach/src/pddl2smach.l")
(require :state-machine-ros "package://roseus_smach/src/state-machine-ros.l")
(require :mongo-client "package://roseus_mongo/euslisp/mongo-client.l")

;; parameters
(defparameter *preempt* t
  "set nil to disable preemption")
(defparameter *preempt-param-key* "/preempt/preempted"
  "param key for preemption flag")
(defparameter *preempted-state-param-key* "/preempt/preempted_state"
  "param key for environmental state on preemption")
(defparameter *preempted-goal-param-key* "/preempt/preempted_goal"
  "param key for goal state of preempted task")
(defparameter *preempt-failure-value* :fail
  "return value of failed action")
(defparameter *preempt-success-value* :success
  "return value of succeeded action")

;; variables
(defvar *condition-updaters* nil
  "Initial condition validators on planning")

;; utilities
(defun pformat (sexp)
  "pprint but returns output as a string"
  (with-output-to-string (s)
    (pprint sexp s)))


;; add interface for pddl / smach
(defmethod transition
  (:pddl-from-state () (car (get self :pddl-state)))
  (:pddl-to-state () (cdr (get self :pddl-state))))
(defmethod state-machine
  (:pddl-initial-state () (car (get self :pddl-state)))
  (:pddl-goal-state () (cdr (get self :pddl-state))))


(defmacro with-check-preemption (&rest form)
  "check / raise preemption signal on form block"
  (let ((ret (gensym "PREEMPT")) (val (gensym "PREEMPT")))
    `(let ((,ret ,@form) ,val)
       (when (memq :preempt-barrier (sys::list-all-catchers))
         (cond ((ros::has-param *preempt-param-key*)
                (setq ,val (ros::get-param *preempt-param-key*))
                (throw :preempt-barrier
                  (if (stringp ,val)
                      (intern (string-upcase ,val) *keyword-package*) ,val)))
               ((and (atom ,ret) (null ,ret))
                (warn "atom: ~A~%" ,ret)
                (throw :preempt-barrier *preempt-failure-value*))
               ((and (listp ,ret) (every #'null ,ret))
                (warn "listp: ~A~%" ,ret)
                (throw :preempt-barrier *preempt-failure-value*))))
       ,ret)))

(defun preempt (&optional (reason :preempt))
  (ros::set-param *preempt-param-key* reason)
  reason)


(defun reset-preempt ()
  (ros::delete-param *preempt-param-key*)
  (ros::delete-param *preempted-state-param-key*)
  (ros::delete-param *preempted-goal-param-key*)
  (unix:usleep (* 500 1000))
  t)


(defun preempted-p ()
  (and (ros::has-param *preempt-param-key*)
       (not (null (ros::get-param *preempt-param-key*)))))


(defmacro defpreemptrobot (name &rest form)
  "This macro defines a subclass of `robot`-interface, where preemption is supported.
The original init function (e.g. pr2-init) is overwritten to initialize an instance of the class.
Example: (defpreemptrobot pr2) creates `pr2-preempt-interface` and `pr2-init`"
  (let ((cls (read-from-string (format nil "~A-preempt-interface" name)))
        (sprcls (read-from-string (format nil "~A-interface" name)))
        (initfunc (read-from-string (format nil "~A-init" name)))
        (initorigfunc (read-from-string (format nil "~A-init-orig" name))))
  `(prog1
    (defclass ,cls
      :super ,sprcls
      :slots ())
    (defmethod ,cls
  (:wait-interpolation
   (&rest args)
   (with-check-preemption
       (some #'null (send-super* :wait-interpolation args))))
  (:move-to
   (&rest args)
   (with-check-preemption
       (send-super* :move-to args)))
  (:move-to-wait
   (&rest args)
   (let ((ret (send-super* :move-to-wait args)))
     (if (send self :preempted-p) nil ret)))
  (:go-pos
   (&rest args)
   (with-check-preemption
       (send-super* :go-pos args)))
  (:go-pos-unsafe
   (&rest args)
   (with-check-preemption
       (send-super* :go-pos-unsafe args)))
  (:move-gripper
   (&rest args)
   (with-check-preemption
       (send-super* :move-gripper args)))
  (:ros-wait
   (&rest args)
   (with-check-preemption
     (send-super* :ros-wait args)))
  (:robot-interface-simulation-callback
   ()
   (when (or (send self :interpolatingp) current-goal-coords)
     (send self :ros-wait 0.03)
     (if (send self :preempted-p) (setq current-goal-coords nil)))
   (send-super :robot-interface-simulation-callback)
   nil)
  (:wait-interpolation-raw
   (&rest args)
   (send-super* :wait-interpolation args))
  (:move-to-raw
   (&rest args)
   (send-super* :move-to args))
  (:go-pos-raw
   (&rest args)
   (send-super* :go-pos args))
  (:go-pos-unsafe-raw
   (&rest args)
   (send-super* :go-pos-unsafe args))
  (:move-gripper-raw
   (&rest args)
   (send-super* :move-gripper args))
  (:preempted-p () (preempted-p))
  (:reset-preempt () (reset-preempt))
  (:preempt
   (&optional (reason :preempted))
   (prog1 (preempt reason)
     (progn ,@form)))
) ;; defmethod
;;
(unless (fboundp ',initorigfunc)
  (setf (symbol-function ',initorigfunc) (symbol-function ',initfunc)))
;;
(defun ,initfunc (&rest args)
  ,(format nil "Initializes *robot* and *ri* for ~A" cls) ;; docstring
  (when (and (not (boundp '*ri*)) *preempt*)
    (setq *ri* (instance ,cls :init)))
  (prog1
      (apply #',initorigfunc args)
    (setq *robot* *pr2*)))
)))

(defmacro defaction (name args &rest form)
  "This is similar to defun, but preemption is supported"
  (let ((ret (gensym "DEFACTION"))
        (name-raw (read-from-string (format nil "~A-raw" name))))
    `(progn
       (defun ,name-raw ,args
         (block ,name (progn ,@form)))
       (defun ,name ,args
         (unless *preempt*
           (return-from ,name (funcall #',name-raw ,@args)))
         (let (,ret)
           (prog1
               (setq ,ret
                     (catch :preempt-barrier
                       (ros::ros-info ";; start ~A" (list ',name))
                       (setq ,ret (block ,name (progn ,@form)))
                       (ros::ros-warn ";; return value: ~A" ,ret)
                       (unless ,ret (throw :preempt-barrier *preempt-failure-value*))
                       *preempt-success-value*))
             (when (and (memq :exec-barrier (sys::list-all-catchers))
                        (not (memq ,ret (list *preempt-failure-value* *preempt-success-value*))))
               (throw :exec-barrier ,ret))) ;; caught by exec-preempt-task
           ,ret)))))

(defun exec-preemptive-task (sm &key (mydata '(nil)))
  "This function is like exec-state-machine in roseus_smach/src/state-machine-utils.l, but supports preemption"
  (let ((insp (instance state-machine-inspector :init sm))
        result pddl-state)
    (unix::sleep 2)
    ;;
    ;; setup state machine
    (send sm :reset-state)
    (send insp :publish-structure) ;; publish once and latch
    (apply #'send sm :arg-keys (union (send sm :arg-keys) (mapcar #'car mydata)))
    ;;
    ;; check / reset preempt status
    (when (boundp '*ri*)
      (send *ri* :ros-wait 0.0 :spin nil :spin-self t)
      (when (send *ri* :preempted-p)
        (ros::ros-warn "The current task is preempted.")
        (unless (y-or-n-p ";; Reset preempt status?")
          (return-from exec-preemptive-task))
        (send *ri* :reset-preempt)))
    ;;
    ;; exec loop
    (setq result
          (catch :exec-barrier
            (while (ros::ok)
              (ros::spin-once)
              (when (boundp '*ri*)
                (send *ri* :ros-wait 0.0 :spin-self t :spin nil))
              ;;
              (send insp :publish-status mydata)
              ;;
              (when (send sm :goal-reached) (return))
              (setq result (send insp :state-machine :execute mydata :step -1))
              ;;
              (let ((trans (car (remove-if-not
                                 #'(lambda (tr) (send tr :check result))
                                 (send (send insp :state-machine :active-state) :arc-list)))))
                (when trans
                  (setq pddl-state (send trans :pddl-to-state))
                  (ros::ros-info ";; state -> ~A" (pformat pddl-state))))
              ) ;; while
            :finish))
    ;;
    ;; check the last pddl state
    (when (and (not (send sm :goal-reached)) (null pddl-state))
      (ros::ros-warn "current pddl-state is empty. use active state transition")
      (let ((trans (car (send (send sm :active-state) :arc-list))))
        (setq pddl-state (send trans :pddl-from-state))))
    (ros::ros-info "task finished with ~A -> ~A" result (pformat pddl-state))
    (when (and (send *ri* :preempted-p)
               (not (null pddl-state)))
      ;; dump current state
      (ros::set-param *preempted-state-param-key* (format nil "~A" pddl-state))
      ;; dump goal state
      (if (send sm :pddl-goal-state)
          (ros::set-param *preempted-goal-param-key*
                          (format nil "~A" (send sm :pddl-goal-state)))
          (ros::ros-warn "PDDL goal state not found. Resume may fail"))
      ) ;; when preempted
    (list result pddl-state))) ;; defaction

(defun merge-states (current updated &key (debug))
  "Resolve conflicts in pddl states and merge them into one state"
  (let ((cur (copy-object current))
        (upd (copy-object updated)))
    ;; prefer current onhand to updated on
    ;; (onhand ?OBJ ?ARM)
    (let ((c (remove-if-not #'(lambda (s) (eq 'onhand (car s))) cur)))
      (dolist (obj (mapcar #'(lambda (s) (cadr s)) c))
        (setq upd (remove-if #'(lambda (s)
                                 (and (eq 'on (car s))
                                      (eq obj (cadr s)))) upd))))
    (when debug
      (warn "remove on~%")
      (warn "cur: ~A~% upd: ~A~%" (pformat cur) (pformat upd)))
    ;;
    ;; prefer current on to updated onhand
    ;; (on ?OBJ ?SPOT)
    ;; NOTE: 逆かも
    (let ((c (remove-if-not #'(lambda (s) (eq 'onhand (car s))) upd)))
      (dolist (obj (mapcar #'(lambda (s) (cadr s)) c))
        (when (find-if #'(lambda (s)
                           (and (eq 'on (car s))
                                (eq obj (cadr s)))) cur)
          (setq upd (remove-if #'(lambda (s)
                                   (and (eq 'onhand (car s))
                                        (eq obj (cadr s)))) upd)))))
    (when debug
      (warn "remove onhand~%")
      (warn "cur: ~A~% upd: ~A~%" (pformat cur) (pformat upd)))
    ;;
    ;; prefer current at
    ;; (at ?SPOT)
    (let ((c (find-if #'(lambda (s) (eq 'at (car s))) cur)))
      (when c
        (setq upd (remove-if #'(lambda (s) (eq 'at (car s))) upd))))
    (when debug
      (warn "remove at~%")
      (warn "cur: ~A~% upd: ~A~%" (pformat cur) (pformat upd)))
    ;;
    ;; prefer updated function to current
    ;; (= (func) num) or (= num (func))
    (let ((fs (remove-if-not #'(lambda (s) (eq '= (car s))) upd)))
      (dolist (f fs)
        (setq cur (remove-if #'(lambda (s)
                                 (and (eq '= (car s))
                                      (equal (find-if #'listp f)
                                             (find-if #'listp s)))) cur))))
    (when debug
      (warn "remove func~%")
      (warn "cur: ~A~% upd: ~A~%" (pformat cur) (pformat upd)))
    ;;
    ;; prefer updated on
    (let ((c (remove-if-not #'(lambda (s) (eq 'on (car s))) upd)))
      (dolist (obj (mapcar #'(lambda (s) (cadr s)) c))
        (setq cur (remove-if #'(lambda (s)
                                 (and (eq 'on (car s))
                                      (eq obj (cadr s)))) cur))))
    ;;
    ;; merge states
    (ros::ros-info "merging current: ~A" (pformat cur))
    (ros::ros-info "updated: ~A" (pformat upd))
    (unique (append cur upd))
    ))

(defun plan-task (domain problem &key (debug) (failed-nodes))
  "Plan action sequence with failure recovery, given domain and problem using PDDL solver.
This function also supports resume from preempted tasks"
  (let ((prob (copy-object problem))
        graph sm)
    ;;
    ;; count failed nodes if not specified
    (unless failed-nodes
      (setq failed-nodes
            (remove-if-not #'(lambda (n)
                               (string= "_f"
                                        (subseq (send n :name)
                                                (- (length (send n :name)) 2))))
                           (send domain :action)))
      (setq failed-nodes
            (mapcar #'(lambda (n)
                        (read-from-string
                         (subseq (send n :name) 0 (- (length (send n :name)) 2))))
                    failed-nodes)))
    ;;
    ;; merge preempted initial states into original initial condition
    (when (ros::has-param *preempted-state-param-key*)
      (let ((cnd (ros::get-param *preempted-state-param-key*)))
        (if (or (not (stringp cnd)) (null-string-p cnd))
            (ros::ros-error "preempted state is empty")
            (setq cnd (read-from-string cnd)))
        (send prob :initial-condition
              (merge-states cnd (send prob :initial-condition)))))
    ;;
    ;; merge preempted goal states into new goal
    (when (ros::has-param *preempted-goal-param-key*)
      (let ((cnd (ros::get-param *preempted-goal-param-key*)))
        (if (or (not (stringp cnd)) (null-string-p cnd))
            (ros::ros-error "preempted goal state is empty. Resume failed")
            (setq cnd (read-from-string cnd)))
        (send prob :goal-condition
              (merge-states cnd (send prob :goal-condition)))))
    ;;
    ;; update conditions using updaters
    (let ((ret (update-condition (send prob :initial-condition)
                                 (send prob :goal-condition))))
      (send prob :initial-condition (car ret))
      (send prob :goal-condition (cadr ret)))
    ;;
    (ros::ros-info "planning from ~A" (pformat (send prob :initial-condition)))
    (ros::ros-info "to goal ~A" (pformat (send prob :goal-condition)))
    ;;
    ;; send domain / problem to pddl solver
    (setq graph (cached-pddl-plan-to-graph nil
                                    :domain domain :problem prob
                                    :failed-nodes failed-nodes
                                    :readable nil
                                    :debug debug))
    (send graph :write-to-pdf "/tmp/graph.pdf" nil "hoge")
    (when debug
      (unix:system "xdg-open /tmp/graph.pdf"))
    ;;
    (setq sm (send (pddl-graph-to-smach graph
                                        :add-self-return-failure-path nil)
                   :state-machine))
    (setf (get sm :pddl-state)
          (cons (send prob :initial-condition)
                (send prob :goal-condition)))
    sm))

;;
;; cached planning
;;
(defun sort-sexp (sexp)
  (cond
    ((atom sexp) sexp)
    ((every #'atom sexp)
     (sort sexp #'<= #'sxhash))
    (t
     (sort (mapcar #'(lambda (s) (sort-sexp s)) sexp) #'<= #'sxhash))))

(defun cached-pddl-plan-to-graph (goal-condition
                                  &key (domain *domain*) (problem *problem*)
                                    (failed-nodes *failed-nodes*) (readable t) (debug) (timeout 0)
                                    (use-cache t))
  (let ((mongo::*mongo-collection* "pddl_planner_cache")
        (domain-sexp (send domain :domain-sexp))
        (problem-sexp (send problem :problem-sexp))
        result msg msg-id)
    (when use-cache
      (setq result (mongo::query roseus::StringStamped
                                 :meta `((:domain . ,(sxhash (sort-sexp domain-sexp)))
                                         (:problem . ,(sxhash (sort-sexp problem-sexp)))
                                         (:failed-nodes . ,(sxhash (sort-sexp failed-nodes)))
                                         (:readable . ,readable))
                                 :sort '((:inserted_at . -1))
                                 :single t
                                 :msg-only t))
      (when result
        (setq result (read-from-string (send (car result) :data)))))
    (when result
      (ros::ros-info "loaded from cache")
      (return-from cached-pddl-plan-to-graph result))
    (setq result (pddl-plan-to-graph goal-condition
                                     :domain domain
                                     :problem problem
                                     :failed-nodes failed-nodes
                                     :readable readable
                                     :debug debug
                                     :timeout timeout))
    (when result
      (setq msg (instance roseus::StringStamped :init))
      (send msg :header :stamp (ros::time-now))
      (send msg :data (with-output-to-string (f) (dump-structure f result)))
      (setq msg-id (mongo::insert msg
                                  :meta `((:domain . ,(sxhash (sort-sexp domain-sexp)))
                                          (:problem . ,(sxhash (sort-sexp problem-sexp)))
                                          (:failed-nodes . ,(sxhash (sort-sexp failed-nodes)))
                                          (:readable . ,readable))))
      (ros::ros-info "cached plan: ~A" msg-id))
    result))

;;
;; condition updater
;;
(defclass condition-updater
  :super propertied-object
  :slots ())

(defmethod condition-updater
  (:init ())
  (:name () (send (class self) :name))
  (:start ()
    (error "Not implemented"))
  (:stop ()
    (error "Not implemented"))
  (:wait-for-ready (&optional timeout)
    (error "Not implemented"))
  (:update-init (init goal)
    (error "Not Implemented"))
  (:update-goal (init goal)
    (error "Not Implemented"))
  (:onhand (st arm)
    (mapcar #'cadr
            (remove-if-not #'(lambda (x)
                               (and (eq (car x) 'onhand)
                                    (eq (caddr x) arm))) st)))
  (:at (st)
    (cadr (find-if #'(lambda (x) (eq (car x) 'at)) st)))
  (:on (st at)
    (mapcar #'cadr
            (remove-if-not #'(lambda (x)
                               (and (eq (car x) 'on)
                                    (eq (caddr x) at))) st)))
) ;; condition-updater

(defun get-updater (cls)
  (find-if #'(lambda (x) (eq (class x) cls)) *condition-updaters*))

(defun add-updater (cls &rest args)
  (unless (subclassp cls condition-updater)
    (error "~A is not a class of condition-updater" cls))
  (when (get-updater cls)
    (ros::ros-info "~A is already added. Replacing to new instance" cls)
    (send (get-updater cls) :stop)
    (setq *condition-updaters*
          (remove (get-updater cls) *condition-updaters*)))
  (push (instance* cls :init args) *condition-updaters*)
  t)

(defun update-condition (init &optional goal)
  (dolist (updater *condition-updaters*)
    (ros::ros-info "[~A] starting" (send updater :name))
    (send updater :start)
    (send updater :wait-for-ready)
    (ros::ros-info "[~A] started" (send updater :name)))
  ;;
  (let ((upd-init (copy-object init))
        (upd-goal (copy-object goal))
        prev-init prev-goal)
    (ros::ros-info "update init")
    (dolist (updater *condition-updaters*)
      (setq prev-init (copy-object upd-init)
            upd-init (send updater :update-init upd-init upd-goal))
      (ros::ros-info "[~A] ~A -> ~A"
                     (send updater :name) prev-init upd-init))
    ;;
    (when goal
      (ros::ros-info "update goal")
      (dolist (updater *condition-updaters*)
        (setq prev-goal (copy-object upd-goal)
              upd-goal (send updater :update-goal upd-init upd-goal))
        (ros::ros-info "[~A] ~A -> ~A"
                       (send updater :name) prev-goal upd-goal)))
    ;;
    (dolist (updater *condition-updaters*)
      (ros::ros-info "[~A] stopping" (send updater :name))
      (send updater :stop))
    ;;
    (list upd-init upd-goal)))

;; load condition updater subclasses
(require :condition-updater "package://interactive_behavior_201409/euslisp/condition-updater.l")
