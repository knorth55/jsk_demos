(defclass measuring-cup-object
  :super cascaded-link
  :slots (
	  ))

(defmethod measuring-cup-object
  (:init
   (&rest args &key (name "measuring-cup") (pos (float-vector 0 0 0)) (rot (unit-matrix 3)) &allow-other-keys)
   (let (link1 b1 b2 b3 b4 b5 b6 b7 b8)
     (send-super* :init :name name args)

     ;; definition of link
     (setq b1 (make-cylinder 45 110))
     (setq b2 (make-cylinder 43 106))
     (send b2 :locate #f(0 0 4))

     (setq b5 (make-cone #f(0 0 -20) (list #f(15 0 0) #f(0 15 0) #f(-15 0 0) #f(0 -15 0))))
     (setq b6 (make-cone #f(0 0 -18) (list #f(13 0 0) #f(0 13 0) #f(-13 0 0) #f(0 -13 0))))
     (setq b5 (body- b5 b6))
     (setq b7 (make-cube 50 50 50))
     (send b7 :locate #f(0 24 -15))
     (setq b5 (body- b5 b7))
     (send b5 :locate #f(0 -40 110))
     
     (setq b3 (make-cube 20 35 80))
     (setq b4 (make-cube 20 31 72))
     (send b4 :locate #f(0 -2 0))
     (setq b4 (body- b3 b4))
     (send b4 :locate #f(0 17 -40))
     (send b4 :locate #f(0 43 110))

     (setq b1 (body+ b1 b4))
     (setq b1 (body- b1 b2))

     (setq b8 (make-cube 17 10 7))
     (send b8 :locate #f(0 0 -3))
     (send b8 :locate #f(0 -41 111))
     (setq b1 (body- b1 b8))


     (setq link1 (instance bodyset-link :init (make-cascoords) :bodies (list b1 b5) :weight 1 :centroid (float-vector 0.0 0.0 0.0) :inertia-tensor #2f((1.0 0.0 0.0) (0.0 1.0 0.0) (0.0 0.0 1.0))))


     ;; definition of assoc
     (send self :assoc link1)

     ;; definition of end-coords

     ;; definition of joint

     ;; definition of :handle

     ;; init-ending 
     (setq links (list link1))
     (send self :init-ending)
     (send self :move-to (make-coords :pos pos :rot rot))
     (send-all links :worldcoords)

     self))

  )

(defun measuring-cup (&rest args) (instance* measuring-cup-object :init args))