(in-package :cl-glpk)

;;; This high-level interface provides a macro that can be used as shown
;;; in the README.
;;; 
;;; Features:
;;; – coefficients & bounds can be arbitrary lisp forms
;;; - terms in constraints don't have to be in same order as in the objective
;;;   function
;;; - (+ (* 4 x)) can be abbreviated as (* 4 x)
;;; - (* 1 x) can be abbreviated as x
;;; - not all variables need to occur in every constraint
;;; - variables can be left out of bounds list, indicating free variables
;;; - instead of :LOWER and :UPPER, use (<= lb (+ (* 4 x) ...) ub) [if there is
;;;   only one bound, you must have the variable before the bound. EG,
;;;   (>= x lb), not (<= lb x)?]
;;; 
;;; TODO:
;;; - integrate bounds with constraints (either discover that it's just as fast
;;;   to combine them, or add code to separate out bounds before expansion)

(defun standardize-equation (form)
  "Converts all equations [(+ (* 4 x) (* 7 y)), x, (* 4 x), etc.] into the form
   ((4 x) (7 y)) to make our processing simpler."
  (mapcar (lambda (term)
            (if (listp term)
                (cdr term)
                (list 1 term)))
          (if (listp form)
              (cdr form)            ; get rid of the +
              (list form))))

(defun separate-bounds (list)
  (let (constraints bounds)
    (mapc (lambda (constraint)
            (let* ((normalized-bounds (get-bounds constraint))
                   (standardized-constraint (cons (standardize-equation (car normalized-bounds))
                                                  (cdr normalized-bounds))))
              (if (= (length (first standardized-constraint)) 1)
                  (let ((variable (second (first standardized-constraint)))
                        (lower (when (second standardized-constraint)
                                 (/ (second standardized-constraint)
                                    (first (first standardized-constraint)))))
                        (upper (when (third standardized-constraint)
                                 (/ (third standardized-constraint)
                                    (first (first standardized-constraint))))))
                    (push (list variable lower upper) bounds))
                  (push standardized-constraint constraints))))
          list)
    (values constraints bounds)))

(defun get-specified-bounds (lower upper)
  (if lower
      (if upper
          (if (eq upper lower) :fixed :double-bound)
          :lower-bound)
      (if upper
          :upper-bound
          :free)))

(defun get-bounds (list)
  (mapcar (lambda (constraint)
            (let ((comparator (car constraint)))
              (ecase (length constraint)
                (3 (ecase comparator
                     (= (list (second constraint)
                              (third constraint)
                              (third constraint)))
                     (<= (list (second constraint) nil (third constraint)))
                     (>= (list (second constraint) (third constraint) nil))
                     ((< > /=) (error "Invalid comparator"))))
                (4 (ecase comparator
                     (<= (list (third constraint)
                               (second constraint)
                               (fourth constraint)))
                     (>= (list (third constraint)
                               (fourth constraint)
                               (second constraint)))
                     ((< > = /=) (error "Invalid comparator")))))))
          list))

(defun make-list-for-mid-level-api (form)
  (destructuring-bind (constraint lower upper) form
    (list (if (listp constraint)
              (string (gensym "AUX"))
              (string constraint))
          (get-specified-bounds lower upper)
          (or lower 0)
          (or upper 0))))

(defun compute-linear-program (direction objective-function &key subject-to bounds)
  (let* ((variables (mapcar #'second (standardize-equation objective-function)))
         (constraint-bounds (get-bounds subject-to))
         (bounds-bounds (get-bounds bounds))
         (constraint-coefficients
           (mapcar (lambda (constraint)
                     (mapcar #'first (standardize-equation (second constraint))))
                   subject-to)))
    ;(format t "cb: ~S, bb: ~S, cc: ~S~%" constraint-bounds bounds-bounds constraint-coefficients)
    (make-instance
     'glpk:linear-problem
     :rows (mapcar #'make-list-for-mid-level-api constraint-bounds)
     :columns (mapcar (lambda (var)
                        (let ((binding (assoc var bounds-bounds)))
                          (if binding
                              (make-list-for-mid-level-api binding)
                              (list (string var) :free 0 0))))
                      variables)
     :constraints (loop for constraint in constraint-bounds
                     for row from 0
                     appending (loop for product in (standardize-equation (car constraint))
                                  for col from 0
                                  collecting (list (1+ row)
                                                   (progn
                                                     #+(or)
                                                     (format t "~a - ~a - ~a~%"
                                                             (second product)
                                                             (position (second product) variables)
                                                             variables)
                                                     (1+ (position (second product) variables)))
                                                   (elt (elt constraint-coefficients row)
                                                        col))))
     :objective (mapcar #'first (standardize-equation objective-function))
     :direction (if (eq direction :maximize) :max :min))))

(defmacro make-linear-program (direction objective-function &key subject-to bounds)
  `(compute-linear-program ',direction
                           ',objective-function
                           :subject-to ',subject-to
                           :bounds ',bounds))

