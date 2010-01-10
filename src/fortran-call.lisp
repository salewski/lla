(in-package :lla)

;;;; Code for interfacing with Fortran calls.


(declaim (inline lb-target-type))
(defun lb-target-type (&rest objects)
  "Find common target type of objects to.  Forces floats, should be
used in LAPACK."
  (binary-code->lla-type
   (reduce #'logior objects :key (lambda (object)
                                   (lla-type->binary-code
                                    (lla-type object))))))


;;; Helper functions that generate the correct LAPACK/BLAS function
;;; names based on a "root" function name.  For some functions
;;; (usually those involving Hermitian matrices), the roots actually
;;; differ based on whether the matrix is real or complex.

(declaim (inline lb-procedure-name lb-procedure-name2))
(defun lb-procedure-name (name lla-type)
  "Evaluate to the LAPACK/BLAS procedure name.  LLA-TYPE has to
evaluate to a symbol.  If you need conditionals etc, do that outside
this macro."
  (check-type name symbol)
  (check-type lla-type symbol)
  (ecase lla-type
    (:single (make-symbol* "%S" name))
    (:double (make-symbol* "%D" name))
    (:complex-single (make-symbol* "%C" name))
    (:complex-double (make-symbol* "%Z" name))))

(defun lb-procedure-name2 (real-name complex-name lla-type)
  "Evaluate to the LAPACK/BLAS procedure name, differentiating real
and complex cases.  :single or :double is returned as the second value
as appropriate, and the third value is true iff lla-type is complex."
  (check-type real-name symbol)
  (check-type complex-name symbol)
  (check-type lla-type symbol)
  (ecase lla-type
    (:single (values (make-symbol* "%S" real-name) :single nil))
    (:double (values (make-symbol* "%D" real-name) :double nil))
    (:complex-single (values (make-symbol* "%C" complex-name) :single t))
    (:complex-double (values (make-symbol* "%Z" complex-name) :double t))))

;;; Some LAPACK procedures can signal errors, they do this via an INFO
;;; output integer.  Here we provide macros to capture these errors.
;;;
;;; Currently, a general lapack-error condition is thrown.  This may
;;; be too coarse, as INFO actually provides quite a bit of
;;; information of what went wrong.  There are usually two kinds of
;;; errors: invalid/nonsensical arguments (should never happen), and
;;; incomputable problems (matrix being singular, usually with
;;; detailed info).  !!! We should capture the latter and provide more
;;; sensible error messages.  Maybe instead of throwing LAPACK-ERROR,
;;; macros should accept a form that tells what kind of error to
;;; signal.  Expect CALL-WITH-INFO-CHECK to be modified in the future,
;;; eg all current arguments go into a list, then body gets PROCEDURE
;;; and INFO values in case of an error and may do what it wants with
;;; them.
;;;
;;; ??? Most (maybe all?) LAPACK functions just have INFO as their
;;; last argument, so WITH-INFO-CHECK may never be used directly.
;;; Should everything be folded into CALL-WITH-INFO-CHECK?

(define-condition lapack-error (error)
  ;; !! write method for formatting the error message
  ((info :initarg :info :type integer :reader info
	 :documentation "info code")
   (lapack-procedure :initarg :lapack-procedure :type symbol
		     :reader lapack-procedure
		     :documentation "The name without the type prefix (eg 'gesv)."))
  (:documentation "The LAPACK procedure returned a nonzero info
  code."))


(defmacro with-info-check ((procedure-name info-pointer) &body body)
  "Evaluate body with info-pointer bound to an integer, and check it
afterwards, signalling an lapack-error condition if info is nonzero."
  ;; !!! how to handle errors nicely? the wrapper can handle this
  ;; condition, and output an error message.  There are generally
  ;; two kinds of errors in LAPACK: (1) malformed inputs, and (2)
  ;; ill-conditioned numerical problems (eg trying to invert a
  ;; matrix which is not invertible, etc).
  ;;
  ;; (1) requires displaying argument names, but in a well-written
  ;; library errors like that should not happen, so we will not
  ;; worry about it (if it does, that requires debugging & fixing,
  ;; not a condition system). In (2), info usually carries all the
  ;; information.
  ;;
  ;; ??? suggestion: an extra argument to the macro on how to
  ;; interpret info and generate an error message? create a class
  ;; hierarchy of conditions. !!!! do this when API has
  ;; stabilized. -- Tamas
  (check-type info-pointer symbol)
  (check-type procedure-name symbol)
  (with-unique-names (info-value)
    `(with-foreign-object (,info-pointer :int32)
       (multiple-value-prog1
	   (progn ,@body)
	 (let ((,info-value (mem-aref ,info-pointer :int32)))
	   (unless (zerop ,info-value)
             ;; ??? two different conditions should be thrown,
             ;; depending on the value of INFO.  Positive INFO usually
             ;; means something substantive (eg a minor is not PSD),
             ;; negative INFO is a bad argument which should never
             ;; happen
             (error 'lapack-error :info ,info-value 
                    :lapack-procedure ',procedure-name)))))))

(defmacro call-with-info-check (procedure &rest arguments)
  "One-liner form that calls the procedure with arguments, and then
checks INFO, which is assumed to be the last argument, using
with-info-check."
  (let ((info-pointer (car (last arguments))))
    (check-type procedure symbol)
    (check-type info-pointer symbol)
    `(with-info-check (,procedure ,info-pointer)
       (funcall ,procedure ,@arguments))))


;;; Some (most?) LAPACK procedures allow the caller to query the
;;; function for the optimal workspace size, this is a helper macro
;;; that does exactly that.  We provide the singular case as a
;;; special case if the plural one instead of the other way around,
;;; since this would not recurse well.

(defmacro with-work-queries ((&rest specifications) &body body)
  "Call body twice with the given work area specifications, querying
the size for the workspace area.  NOTE: abstraction leaks a bit (body
is there twice), but it should not be a problem in practice.  Body is
most commonly a single function call.

SPECIFICATIONS is a list of triplets (SIZE POINTER LLA-TYPE), where
SIZE and POINTER have to be symbols.  Workspace size (an integer) and
the allocated memory area (pointer) are assigned to these."
  (let* ((sizes (mapcar #'first specifications))
         (pointers (mapcar #'second specifications))
         (returned-sizes (mapcar (lambda (pointer) (gensym* 'returned-size-of- pointer)) pointers))
         (foreign-sizes (mapcar (lambda (pointer) (gensym* 'foreign-size-of- pointer)) pointers))
         (lla-types (mapcar (lambda (pointer) (gensym* 'lla-type-of- pointer)) pointers)))
    (assert (every #'symbolp sizes) () "SIZEs have to be symbols")
    (assert (every #'symbolp pointers) () "POINTERs have to be symbols")
    ;; evaluate lla-types, once only
    `(let ,(mapcar (lambda (lla-type specification)
                     `(,lla-type ,(third specification)))
            lla-types specifications)
       ;; calculate atomic foreign object sizes
       (let ,(mapcar (lambda (foreign-size lla-type)
                       `(,foreign-size (foreign-size* ,lla-type)))
              foreign-sizes lla-types)
         ;; placeholder variables for returned-sizes
         (let ,returned-sizes
           ;; allocate memory for sizes
           (with-foreign-objects ,(mapcar (lambda (size) `(,size :int32 1)) sizes)
             ;; query returned sizes
             ,@(mapcar (lambda (size) `(setf (mem-ref ,size :int32) -1)) sizes)
             (with-foreign-pointers ,(mapcar (lambda (pointer foreign-size)
                                               `(,pointer ,foreign-size))
                                             pointers foreign-sizes)
               ,@body
               ,@(mapcar (lambda (returned-size pointer lla-type size)
                           `(setf ,returned-size (floor (mem-aref* ,pointer ,lla-type))
                                  (mem-ref ,size :int32) ,returned-size))
                         returned-sizes pointers lla-types sizes))
             ;; allocate and call body again
             (with-foreign-pointers ,(mapcar (lambda (pointer foreign-size returned-size)
                                               `(,pointer (* ,foreign-size ,returned-size)))
                                             pointers foreign-sizes returned-sizes)
               ,@body)))))))



(defmacro with-work-query ((size pointer lla-type) &body body)
  "Single-variable version of WITH-WORK-QUERIES."
  `(with-work-queries ((,size ,pointer ,lla-type)) ,@body))

(defmacro with-work-area ((pointer lla-type size) &body body)
  "Allocate a work area of size lla-type elements during body,
assigning the pointer to pointer."
  (check-type pointer symbol)
  `(with-foreign-pointer (,pointer 
			  (* ,size (foreign-size* ,lla-type)))
     ,@body))

(define-with-multiple-bindings with-work-area)


;;;; Miscellaneous utility functions.

(defun nv-zip-complex-double (pointer n &optional check-real-p)
  "Return the complex numbers stored at pointer (n real parts,
followed by n imaginary parts) as a numeric vector (either double or
complex-double).  If check-real-p, then check if the imaginary part is
0 and if so, return a numeric-vector-double, otherwise always return a
complex-double one.  Rationale: some LAPACK routines return real and
imaginary parts of vectors  separately, we have to assemble them."
  (let ((real-p (and check-real-p 
                     (iter
                       (for i :from 0 :below n)
                       (always (zerop (mem-aref pointer :double (+ n i))))))))
    (if real-p
        (let ((elements (make-array n :element-type 'double-float)))
          (iter
            (for i :from 0 :below n)
            (setf (aref elements i) (mem-aref pointer :double i)))
          (make-nv* :double elements))
        (let ((elements (make-array n :element-type '(complex double-float))))
          (iter
            (for i :from 0 :below n)
            (setf (aref elements i) (complex (mem-aref pointer :double i)
                                         (mem-aref pointer :double (+ n i)))))
          (make-nv* :complex-double elements)))))

;;; Collecting the matrix/vector at the end.

(defun matrix-from-first-rows (nv m nrhs n)
  "Extract & return (as a dense-matrix) the first n rows of an m x
nrhs matrix, stored in nv in column-major view.  NOTE: needed to
interface to LAPACK routines like xGELS."
  ;; It is assumed that NV's ELEMENTS has the correct type.
  (let* ((elements (elements nv))
         (result (make-array (* n nrhs) :element-type (array-element-type elements))))
    (dotimes (col nrhs)
      (iter
        (repeat n)
        (for elements-index :from (* col m))
        (for result-index :from (* col n))
        (setf (aref result result-index) (aref elements elements-index))))
    (make-matrix* (lla-type nv) n nrhs result)))

(defun sum-last-rows (nv m nrhs n)
  "Sum & return (as a numeric-vector of the appropriate type) the last
m-n rows of an m x nrhs matrix, stored in nv in column-major view.
NOTE: needed to interface to LAPACK routines like xGELS."
  (let* ((elements (elements nv))
         (lisp-type (array-element-type elements))
         (result (make-array nrhs :element-type lisp-type
                             :initial-element (coerce 0 lisp-type))))
    (dotimes (col nrhs)
      (setf (aref result col)
            (coerce 
             (iter
               (repeat (- m n))
               (for elements-index :from (+ (* col m) n))
               (summing (expt (abs (aref elements elements-index)) 2)))
             lisp-type)))
    (make-nv* (lla-type nv) result)))
