(in-package :lla)

(define-make-symbol% :lla)

(deftype symbol* () '(and symbol (not null)))
(defun symbolp* (object) (typep object 'symbol*))

(defmacro row-major-loop ((dimensions row-major-index row-index col-index &key
                                      (nrow (gensym* '#:nrow))
                                      (ncol (gensym* '#:ncol)))
                          &body body)
  "Loop through row-major matrix with given DIMENSIONS, incrementing
ROW-MAJOR-INDEX, ROW-INDEX and COL-INDEX."
  (check-types (row-index col-index row-major-index nrow ncol) symbol)
  `(bind (((,nrow ,ncol) ,dimensions)
          (,row-major-index 0))
     (dotimes (,row-index ,nrow)
       (dotimes (,col-index ,ncol)
         ,@body
         (incf ,row-major-index)))))

(defmacro define-ondemand-slot ((instance-and-class slot-name) &body body)
  `(defmethod slot-missing (,(gensym) ,instance-and-class (slot-name (eql ',slot-name))
                            (operation (eql 'slot-value)) &optional new-value)
     (declare (ignore new-value))
     ,@body))


;;;; this is missing from CFFI at the moment
(define-with-multiple-bindings with-foreign-pointer)

;; ;; #+sbcl (eval-when (:compile-toplevel :load-toplevel :execute)
;; ;;          (pushnew :muffle-notes cl:*features*))

;; (declaim (inline as-scalar%))
;; (defun as-scalar% (vector)
;;   "Pick the first element from a vector.  No checking."
;;   (row-major-aref vector 0))

;; ;;; muffling notes
;; (defmacro muffle-optimization-notes (&body body)
;;   "This macro silences compiler optimization notes."
;;   `(locally 
;;        #+sbcl (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
;;        ,@body))

;; (defun maybe-wrap-list (prefix body)
;;   "When PREFIX, wraps BODY in a list, starting with PREFIX, otherwise
;; return BODY.  Intended for use in macros."
;;   (if prefix
;;       (list (concatenate 'list prefix body))
;;       body))

;; (defun maybe-wrap (prefix &rest body)
;;   "When PREFIX, wraps BODY in a list, starting with PREFIX, otherwise
;; return BODY.  Intended for use in macros."
;;   (maybe-wrap-list prefix body))

;; ;;; array utilities

;; (declaim (inline zero-like))
;; (defun zero-like (array)
;;   "Return 0 coerced to the element type of ARRAY."
;;   (coerce 0 (array-element-type array)))

;; ;;; unfortunately, simple-vector is already taken by CL, for element
;; ;;; types T, so we define the new type SIMPLE-ARRAY1
;; (deftype simple-array1 (&optional element-type length)
;;   `(simple-array ,element-type (,length)))

;; (defun simple-array? (object)
;;   (typep object 'simple-array))

;; (defun simple-array1? (object)
;;   (typep object 'simple-array1))

;; (defun as-simple-array1 (array)
;;   "Return elements of ARRAY as a SIMPLE-ARRAY1.  Array is not
;; necessarily copied if it is already of the correct type."
;;   (etypecase array
;;     (simple-array1 array)
;;     (array (copy-seq (displace-array array (array-total-size array))))))
