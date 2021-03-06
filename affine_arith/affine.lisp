(defparameter *aa-builtin* '(("+" "ADD") ("-" "SUB") ("*" "MULT") ("^" "POW")))
  
(defparameter *aa-extended* nil)

(defparameter *aa-let-names* nil)

(defparameter *affine-strategies* "
%  affine: Computes bounds to minimum and maximum values of real-valued expressions.
%  aff-simple: Computes bounds to minimum and maximum values of real-valued expressions.
%  aff-numerical: Computes bounds to minimum and maximum values of real-valued expressions.
%  Supported operations include: +,-,*,^")

;;-------------------------------------------------------------------------------
;;-- basic affine arithmetic strategy -------------------------------------------
;;-------------------------------------------------------------------------------

(unintern 'aa-info)
(defstruct aa-info
  idx ; Specific index in the Affine Form (introduced by this expression).
  aff ; Affine Form
  nvl ; Noise value
)

(unintern 'aa-core)
(defstruct aa-core
  vars      ; original list of variables
  work-info ; working info (hashtable of Affine Form, noise value, and noise index)
  c-noise-l ; current noise as a list of aa-info (stored in reverse order).
)

(defparameter *aa-core* nil)

(defun aa-core-var-noise (core var-str)
  (aa-info-nvl (gethash var-str (aa-core-work-info core))))

(defun c-noise-l-to-noise-expr (resulting-str info)
  (format nil "extend_N(~a::nat,~a::Epsilon,~a)" (aa-info-idx info) (aa-info-nvl info) resulting-str))

;; Builds an expression that denotes the current noise.
(defun aa-core-cur-noise (core)
    (reduce #'c-noise-l-to-noise-expr
	    (aa-core-c-noise-l core)
	    :initial-value "empty_noise"))

;; Returns the greatest partial deviation index used in the current affine form
;; build.
(defun aa-core-great-idx (core)
  (length (aa-core-c-noise-l core)))

(defun build-aa-core (vars)
  (let*((work-info (make-hash-table :test #'equal))
	(c-noise-l (loop for v in (reverse vars)
			 for varindex from (- (length vars) 1) downto 0
			 for noiseval = (freshname (format nil "epsilon_~a" v))
			 for varrange = (gethash v *extra-varranges*)
			 for aff-form = (format nil "var_ac([|~a,~a|],~a)"
						(xterval-lb varrange)
						(xterval-ub varrange)
						varindex)
			 for info     = (make-aa-info :idx varindex :aff aff-form :nvl noiseval)
			 do (setf (gethash v work-info) info)
			 collect info)))
    (make-aa-core :vars vars
		  :work-info work-info
		  :c-noise-l c-noise-l)))

(defun aa-core-get-aa-expr-var (core var-expr)
  (let*((expr-as-str (expr2str var-expr))
	(result      (gethash expr-as-str (aa-core-work-info core))))
    ;; The information about the variables should be already loaded in the
    ;; aa-core, if we can not get the information for the requested variable,
    ;; something wrong happened.
    (unless result
      (error "aa-core-get-aa-expr-var: information about the variable couldn't be found."))
    (aa-info-aff result)))

(defun aa-core-get-aa-expr-mul (core expr)
  (let*((expr-as-str (expr2str expr))
	(result      (gethash expr-as-str (aa-core-work-info core))))
    ;; If the information about this expression has been computed already, then
    ;; we will use it. If not, we will compute it and store it in the aa-core.
    (unless result
      (let*((aff-expr1 (aa-ac-from-expr-rec (args1 expr) core))
	    (aff-expr2 (aa-ac-from-expr-rec (args2 expr) core))
	    (mul-noise (format nil "mul_noise_value(~a,~a,~a)"
			       aff-expr1
			       aff-expr2
			       (aa-core-cur-noise core)))
	    (mul-index (aa-core-great-idx core))
	    (mul-aaexp (format nil "mult_ac_ac(~a,~a,~a)"
			     aff-expr1
			     aff-expr2
			     mul-index))
	    (info      (make-aa-info :idx mul-index :aff mul-aaexp :nvl mul-noise)))
	(setf (gethash expr-as-str (aa-core-work-info core)) info)
	(setf (aa-core-c-noise-l core) (cons info (aa-core-c-noise-l core)))
	(setf result info)))
    (aa-info-aff result)))

;; Constructs an affine combination that represents the expression expr.
(defun aa-ac-from-expr (expr vars)
  (setf *aa-core* (build-aa-core vars))
  (catch '*aa-error* (aa-ac-from-expr-rec expr *aa-core*)))

(defun aa-ac-from-expr-rec (expr core)
  (let ((val (when (or (is-number-type (type expr)) (is-bool-type (type expr)))
	       (typecheck (extra-add-evalexpr expr)))))
    (cond ;; constant
          ((and val (is-number-type  (type val)))
	   (format nil "const_ac(~a)" val))
	  ;; variable
	  ((is-variable-expr expr)
	   (aa-core-get-aa-expr-var core expr))
	  ;; additive inverse
	  ((and (unary-application? expr)
		(is-function-expr expr "-"))
	   (format nil "neg_ac(~a)" (aa-ac-from-expr-rec (args1 expr) core)))
	  ;; substraction
	  ((is-function-expr expr "-")
	   (format nil "sub_ac_ac(~a,~a)"
		   (aa-ac-from-expr-rec (args1 expr) core)
		   (aa-ac-from-expr-rec (args2 expr) core)))
	  ;; addition
	  ((is-function-expr expr "+")
	   ;; Now I have to check If the first parameter is a constant expression.
	   (if (get-vars-from-expr (args1 expr))
	       (format nil "add_ac_ac(~a,~a)"
		       (aa-ac-from-expr-rec (args1 expr) core)
		       (aa-ac-from-expr-rec (args2 expr) core))
	     (format nil "add_s_ac(~a,~a)"
		     (args1 expr)
		     (aa-ac-from-expr-rec (args2 expr) core))))
	  ;; multiplication
	  ((is-function-expr expr "*")
	   ;; Now I have to check If the first parameter is a constant expression.
	   (if (get-vars-from-expr (args1 expr))
	       (aa-core-get-aa-expr-mul core expr)
	     (format nil "mul_s_ac(~a,~a)"
		     (args1 expr)
		     (aa-ac-from-expr-rec (args2 expr) core))))
	  (t (throw '*aa-error* (list (format nil "Main operator in ~a not supported yet." expr)))))))

(defparameter *aa-rws*
' ("first__extend_N"
   "gnbi_extend_N_trivial"
   "gnbi_extend_N_unf"
   "containment_cnt"
   "var_ac_noise_unf3"
   "containment_sub"
   "containment_add"
   "containment_mul"
   "containment_mul_s"
   "containment_add_s"
   "containment_neg"))

(defparameter *affine-num-count* 0)

(defstep affine (&optional (fnum 1) (default-range "[|0,1|]"))
  (with-fresh-labels
   ((af! fnum))
   (assert af!)
   (let ((formula (extra-get-formula fnum))
	 (target  (args2 formula))
	 (expr    (args1 formula))
	 (vars    (get-vars-from-expr expr))
	 (fms     (append
		   (mapcar #'(lambda (f) (extra-get-formula-from-fnum f))
			   (extra-get-fnums '-))
		   (mapcar #'(lambda (f) 
			       (make-negation
				(extra-get-formula-from-fnum f)))
			   (extra-get-fnums '+))))
	 (af-vars (extra-get-var-ranges fms vars))
	 (unvars  (ia-find-unbound-vars af-vars))
	 (af-expr (aa-ac-from-expr expr af-vars))
	 (f-noise (aa-core-cur-noise *aa-core*))
	 (msg     (when (listp af-expr) (car af-expr))))
     (if msg
	 (printf msg)
       (then
	(with-fresh-names
	 ((af_name_ af-expr))
	 (let ((castr  (format nil "containment(~a,~a)" expr af_name_))
	       (ebyint (format nil "eval_by_intervals(~a)" af_name_)))
	  (spread
	   (case castr)
	   ((then
	     (use "containment_interval")
	     (prop)
	     
	     (if (is-function-expr formula "##")
		 (then
		  (use "Member_trans" ("x" expr  "X" ebyint  "Y" target))
		  (assert)
		  (eval-formula 1))
		(then
		 (eval-expr ebyint)
		 (expand "##")
		 (assert))))
	    (then                       ; Second branch of (case "containment(
					; expr, af_name_)"). Here we know that
					; that the formula 1 is exactly that one.
	     (expand af_name_ :assert? none)
	     (let((vars-count (length vars))
		  (xxx        (setf *affine-num-count* 0)))
	       (then
		(for$ vars-count
		     (let((cur-var (nth *affine-num-count* vars))
			  (eps-var (aa-core-var-noise *aa-core* cur-var))
			  (idx-var *affine-num-count*)
			  (dummy (setf *affine-num-count* (+ *affine-num-count* 1))))
		       (then
			(use "containment_var" ("x" cur-var "n" idx-var))
			(spread (prop) ((skolem -1 eps-var) (then (expand "##")(assert)))))))
		(expand "containment" :assert? none)
		(with-fresh-names
		 ((noise    f-noise))
		 (inst 1 noise)
		 (expand noise :assert? none)
		 (let((rws *aa-rws*)) (apply (repeat* (rewrites rws :fnums 1))))
		 (eval-formula 1)))))))))
	(eval-formula 1)))))
  "do affine"
  "doing affine")

;--------------------------------------------------------------------------------
;-- simple branch and bound strategy --------------------------------------------
;--------------------------------------------------------------------------------
;; Form a string representing the box of variables vars
(defun aa-box (vars)
  (if vars
      (let ((intervals (ia-var-intervals vars)))
	(format nil "(: ~{~a~^,~} :)" (loop for int in intervals
					    collect int)))
    "(::)"))

(defstep aff-simple (expr &optional (precision 3) (n 3) (maxdepth 5))
  (let ((name    (freshname "sia"))
	(ia-expr (extra-get-expr expr))
	(ia-estr (expr2str ia-expr))
	(fms     (mapcar #'(lambda (fn) (extra-get-formula-from-fnum fn)) (extra-get-fnums '-)))
	(vars    (ia-get-vars-from-expr ia-expr))
	(ia-vars (extra-get-var-ranges fms vars))
	(unvars  (ia-find-unbound-vars ia-vars))
	(msg     (cond (unvars
			(format nil "Variable~:[~;s~] ~{~a~^, ~} ~:[is~;are~] unbounded."
				(cdr unvars) unvars (cdr unvars)))
		       ((null ia-expr)
			(format nil "Do not understand argument ~a." expr))
		       ((not (is-number-expr ia-expr))
			(format nil "Expresion ~a is not a real number expression." ia-expr))))
	(aa-box    (unless msg (aa-box ia-vars)))
	(ia-iexpr  (unless msg (aa-affine-expr ia-expr n ia-vars)))
	(maxdepth  (if (null ia-vars) 0 maxdepth))
	(ia-eval   (format nil "simple_affine(~a,~a,~a)" maxdepth name aa-box))
	(ia-lvars  (format nil "list2array(0)((:~{~a~^, ~}:))" ia-vars))
	(msg       (or msg (when (listp ia-iexpr) (car ia-iexpr)))))
    (if msg
	(printf msg)
      (spread
       (name-label name ia-iexpr :hide? t)
       ((try-branch
	 (eval-expr ia-eval :safe? nil)
	 ((then (lemma "simple_affine_soundness")
		(inst? -1)
		(replaces -2)
		(beta -1)
		(expand "sound?" -1)
		(branch (split -1)
			((spread (inst -1 ia-lvars)
				 ((branch (invoke (case "%1 = %2") (! -1 1) ia-estr)
					  ((then (replaces -1)
						 (decimalize -1 precision))
					   (interval-eq__ name 1)
					   (then (hide -1)(vars-sharp__))))
				    (vars-in-box__$)))
			 (eval-formula))))
	  (skip))
	 (skip))))))
  "[Affine] Computes a simple estimation of the minimum and maximum values
of EXPR using a branch and bound algorithm based on affine arithmetic.
PRECISION is the number of decimals in the output interval. The parameter N
concerns the accuracy of the computations of real-valued functions in EXPR.
The higher the value of N, the more accurate the computation of these functions.
MAXDEPTH is a maximum recursion depth for the branch and bound algorithm.

This strategy is a simplified version of the more elaborated strategy NUMERICAL."
  "Computing estimates to the minmax of expression ~a,~%using affine arithmetic")

;;
;; aa-affine-expr
;;
;; Return a string representing an affine expression of expr, where
;;   - n      : approximation parameter
;;   - var    : list of variables
;;   - subs   : list of substitutions of the general form (<f> (<F> <n>) <arity>)
;; Output:
;;   - Expr such that EXISTS(N:Noise):
;;     eval_ACExpr_Env(expr,vs) ## eval_ac_noise(Eval_ACExpr_Box(expr,box),N)
(defun aa-affine-expr (expr n vars &optional subs)
  (setq *aa-let-names* nil)
  (catch '*aa-error*
    (aa-affine-expr-rec expr n vars
			(append subs *aa-builtin* *aa-extended*)
			nil)))

(defun aa-error (msg)
  (throw '*aa-error* (list msg)))


(defun aa-affine-expr-rec (expr n vars subs extended &optional localvars)
  (let ((val (when (or (is-number-type (type expr)) (is-bool-type (type expr)))
	       (typecheck (extra-add-evalexpr expr)))))
    (cond ((and val (is-number-type  (type val)))
	   (format nil "r2E(~a)" val))
	  ((and val (is-bool-type (type val)))
	   (format nil "b2B(~a)" val))
	  ((is-const-decl-expr expr (mapcar #'car subs)) ;; Is a constant, but not a rational one
	   ;; At this point, imported chain is OK. 
	   (let ((opl (ia-idsubs? (expr2str expr) subs)))
	     (if opl
		 (let ((op (cadr opl)))
		   (if (listp op)
		       (format nil "~a(~a)" (car op) (ia-approx-n n (nth 1 op)))
		     (format nil "~a" op)))
	       (aa-error (format nil "Don't know how to translate constant ~a" expr)))))
	  ((is-variable-expr expr)
	   (let ((vl (when (name-expr? expr)
		       (member (id expr) localvars :test #'(lambda(x y) (equal x (car y)))))))
	     (if vl (ia-format-local-var vl (length vars))
	       (let ((vl (member (expr2str expr) vars :test #'string=)))
		 (if vl
		     (format nil "X(~a)" (- (length vars) (length vl)))
		   (aa-error (format nil "Don't know how to translate variable ~a" expr)))))))
	  ((and (unary-application? expr)
		(is-function-expr expr "-"))
	   (format nil "NEG(~a)"
		   (aa-affine-expr-rec (args1 expr) n vars subs extended localvars)))
	  ((is-function-expr expr "^")
	   (cond  ;; Simple version of Power (integer power applyed on a variable)
	          ((and (is-variable-expr (args1 expr)) (is-number-type (type (args2 expr))))
		   (let*((pow  (args2 expr))
			 (expr (args1 expr))
			 (vl   (when (name-expr? expr)
				 (member (id expr) localvars :test #'(lambda(x y) (equal x (car y)))))))
		     (if vl (ia-format-local-var vl (length vars))
		       (let ((vl (member (expr2str expr) vars :test #'string=)))
			 (if vl
			     (format nil "POWVAR(~a,~a)"
				     (- (length vars) (length vl)) pow)
			   (aa-error (format nil "Don't know how to translate ~a as a simple exponentation" expr)))))))
		  ;; General power operation.
		  (t (aa-error (format nil "Unsupported operation: ~a" expr)))))
	  ((arg-tuple-expr? expr)
	   (format nil "~{~a~^,~}"
	  	   (mapcar #'(lambda(x)(aa-affine-expr-rec x n vars subs extended localvars))
	  		   (exprs expr))))
	  ((is-function-expr expr)
	   (let ((opl (ia-idsubs? (id (operator expr)) subs)))
	     (if opl 
	  	 (let ((op (cadr opl)))
	  	   (if (listp op)
	  	       (format nil "~a(~a)(~a)"
	  		       (car op) (ia-approx-n n (nth 1 op))
	  		       (aa-affine-expr-rec (args1 expr) n vars subs extended localvars))
	  	     (format nil "~a(~a)" op
	  		     (aa-affine-expr-rec (argument expr) n vars subs extended localvars))))
	       (aa-error (format nil "Don't know how to translate function ~a" (id (operator expr)))))))
	  (t (aa-error (format nil "Don't know how to translate expression ~a" expr))))))


;--------------------------------------------------------------------------------
;-- Numerical branch and bound strategy -----------------------------------------
;--------------------------------------------------------------------------------
(defstep aff-numerical (expr &optional (precision 3) (maxdepth 10)
			 min? max?
			 vars 
			 dirvar
			 verbose?
			 label
			 (equiv? t))
  (let ((subs      nil)
	(name      (freshname "nml"))
	(label     (or label (freshlabel name)))
	(accuracy  (ratio2decimal (expt 10 (- precision)) nil precision))
	(ia-expr   (typecheck (extra-get-expr expr)))
	(ia-estr   (expr2str ia-expr))
	(fms       (append (mapcar #'(lambda (f) (extra-get-formula-from-fnum f))
				   (extra-get-fnums '-))
			   (mapcar #'(lambda (f) 
				       (make-negation
					(extra-get-formula-from-fnum f)))
				   (extra-get-fnums '+))))
	(vars      (ia-complete-vars (enlist-it vars) (ia-get-vars-from-expr ia-expr subs)))
	(initeqs   (extra-reset-evalexprs))
	(ia-vars   (extra-get-var-ranges fms vars))
	(unvars    (ia-find-unbound-vars ia-vars))
	(msg       (cond (unvars
			  (format nil "Variable~:[~;s~] ~{~a~^,~} ~:[is~;are~] unbounded."
				  (cdr unvars) unvars (cdr unvars)))
			 ((null ia-expr)
			  (format nil "Do not understand argument ~a." expr))
			 ((not (is-number-type (type ia-expr)))
			  (format nil "Expresion ~a is not a real number expression." ia-expr))))
	(ia-box    (unless msg (ia-box ia-vars)))
	(m_or_m    (+ (if min? -1 0) (if max? 1 0)))
	(ia-iexpr  (unless msg (aa-affine-expr ia-expr precision ia-vars subs)))
	(names     (unless msg (append (mapcar #'car *aa-let-names*) (list name))))
	(exprs     (unless msg (append (mapcar #'cdr *aa-let-names*) (list ia-iexpr))))
	(namexprs  (merge-lists names exprs))
	(ia-dirvar (or dirvar (cond ((< m_or_m 0) "mindir_maxvar")
				    ((> m_or_m 0) "maxdir_maxvar")
				    (t "altdir_maxvar"))))
	(maxdepth  (if (null ia-vars) 0 maxdepth))
	(ia-eval   (format nil "numerical(~a,~a,~a,~a)(~a,~a)"
			   maxdepth accuracy ia-dirvar m_or_m name ia-box))
	(ia-lvars  (format nil "list2array(0)((:~{~a~^, ~}:))" ia-vars))
	(msg       (or msg (when (listp ia-iexpr) (car ia-iexpr)))))
    (if msg
	(printf msg)
      (spread
       (name-label* namexprs :hide? t)
       ((try-branch
	 (eval-expr ia-eval :safe? nil)
	 ((let ((output (args2 (extra-get-formula -1)))
		(depth  (extra-get-number-from-expr (get-expr-from-obj output 'depth)))
		(splits (get-expr-from-obj output 'splits))
                (ans    (args1 (get-expr-from-obj output 'ans)))
		(lbacc  (ratio2decimal (- (extra-get-number-from-expr 
					   (get-expr-from-obj ans 'lb_max))
					  (extra-get-number-from-expr 
					   (get-expr-from-obj ans 'mm 'lb)))
				       true precision))
		(ubacc  (ratio2decimal (- (extra-get-number-from-expr 
					   (get-expr-from-obj ans 'mm 'ub))
					  (extra-get-number-from-expr 
					   (get-expr-from-obj ans 'ub_min)))
				       true precision))
		(eqs    (extra-evalexprs))
		(maxd   (and ia-vars (= depth maxdepth))))
	    (with-fresh-labels 
	     (!iax)
	     (relabel label -1)
	     (lemma "numerical_soundness")
	     (inst? -1)
	     (replaces label)
	     (beta -1)
	     (expand "sound?" -1)
	     (apply (repeat (expand "length" -1)))
	     (extra-evalexprs$ eqs !iax)
	     (branch
	      (split -1)
	      ((then
		(flatten)
		(relabel label (-2 -3 -4 -5))
		(hide label)
		(spread
		 (inst -1 ia-lvars)
		 ((branch
		   (invoke (case "%1 = %2") (! -1 1) ia-estr)
		   ((then
		     (when verbose?
		       (printf "~%----")
		       (when maxd
		     	 (printf "Maximum depth has been reached."))
		       (printf "Lower bound accuracy <= ~a" lbacc) 
		       (printf "Upper bound accuracy <= ~a" ubacc)
		       (printf "Splits: ~a. Depth: ~a~%----~%" splits depth)
		       (printf "See hidden formulas labeled \"~a\" for more information"
		     	       label))
		     (replaces -1)
		     (decimalize -1 precision))
		    (then (hide -1) (when equiv? (interval-eq__$ names 1 subs)))
		    (then (hide -1) (reveal !iax) (replaces !iax :hide? nil) (vars-sharp__$))))
		  (if (null ia-vars)
		      (eval-formula)
		    (then 
		     (reveal !iax)
		     (replaces !iax :hide? nil) 
		     (vars-in-box__$))))))
	       (eval-formula)))))
	  (skip))
	 (skip))))))
  "[Affine] Computes lower and upper bounds of the minimum and
maximum values of EXPR using a branch and bound algorithm based on
affine arithmetic.  PRECISION is the number of decimals in the
output interval. PRECISION also indicates an accuracy of 10^-PRECISION
in every atomic computation. However, this accuracy is not guaranteed
in the final result. MAXDEPTH is a maximum recursion depth for the
branch and bound algorithm. For efficiency, the MIN? and MAX? options
can be used to restrict the precision of the computations to either
the lower or upper bound, respectively.

VARS is a list of the form (<v1> ... <vn>), where each <vi> is either a
variable name, e.g., \"x\", or a list consisting of a variable name and
an interval, e.g., (\"x\" \"[|-1/3,1/3|]\"). This list is used to specify
the variables in EXPR and to provide their ranges. If this list is not
provided, this information is extracted from the sequent.

DIRVAR is the name of a direction and variable selection method for
the branch an bound algorithm. Theory affine_bandb_numerical includes some
pre-defined methods. If none is provided, a choice is made base on the
problem.

If VERBOSE? is set to t, the strategy prints information about number of
splits, depth, etc. 

LABEL is used to label formulas containing additional information computed
by the branch and bound algorithm. These formulas are hidden, but they can
be brought to the sequent using the proof command REVEAL.

If EQUIV? is set to nil, the strategy doesn't try to prove that the
deep embedding of the original expression is correct. The proof of
this fact is trivial from a logical point of view, but requires
unfolding of several definitions which is time consuming in PVS."
  "Computing minmax values of expression ~a,~%via affine arithmetic")




;--------------------------------------------------------------------------------
;-- Helper strategies -----------------------------------------------------------
;--------------------------------------------------------------------------------

(defstep expand_ol ()
  (expand* "null_ol?" "car_ol" "cdr_ol" "cons_ol" "empty_ErrorTerms" "empty_noise")
  "Expands trivial definitions from ordered_list theory."
  "Expanding definitions from oredered_list theory.")


;------------------------------------------------------------------------------;

;;
;; Simple helper strategy intended to deal with inequalities on nontrivial terms.
;;
(defun get-sub-expr-at-level (expr n)
  (if (eq n 0) (list expr)
    (when (application? expr)
      (if (tuple-expr? (argument expr))
	  (let ((result nil))
	    (loop for arg in (exprs(argument expr))
		  do (setq result (append result (get-sub-expr-at-level arg (-  n 1)))))
	    result)
	(get-sub-expr-at-level (argument expr) (- n 1))))))

(defstep abstract-and-then (fnums level steps)
  (let ((exprs (get-sub-expr-at-level (extra-get-expr (list '! fnums)) level))
	(names (freshnames "ABS" (length exprs)))
	(names-and-exprs nil)
	(names-and-exprs (loop for expr in exprs
				  for i upto (- (length exprs) 1)
				  collect (nth i names)
				  collect (nth i exprs))))
    (then
     (name-replace* names-and-exprs)
     (then steps)))
  "" "")
	
