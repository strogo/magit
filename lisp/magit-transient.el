;;; magit-transient.el --- support for transients  -*- lexical-binding: t -*-

;; Copyright (C) 2008-2019  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; This library implements Magit-specific prefix and suffix classes,
;; and their methods.

;;; Code:

(eval-when-compile
  (require 'subr-x))

(require 'transient)

(require 'magit-git)
(require 'magit-mode)
(require 'magit-process)

;;; Classes

(defclass magit--git-variable (transient-variable)
  ((multival    :initarg  :multival
                :initform nil)))

(defclass magit--git-variable:choices (magit--git-variable)
  ((choices     :initarg  :choices)
   (fallback    :initarg  :fallback
                :initform nil)
   (default     :initarg  :default
                :initform nil)))

(defclass magit--git-variable:urls (magit--git-variable)
  ((seturl-arg  :initarg  :seturl-arg
                :initform nil)
   (prompt      :initform "Urls: ")))

;;; Methods
;;;; Init

(cl-defmethod transient-init-value ((obj magit--git-variable))
  (let ((variable (format (oref obj variable)
                          (oref transient--prefix scope))))
    (oset obj variable variable)
    (oset obj value
          (cond ((oref obj multival)
                 (magit-get-all variable))
                (t
                 (magit-git-string "config" "--local" variable))))))

;;;; Set

(cl-defmethod transient-infix-read ((obj magit--git-variable))
  (if (oref obj value)
      (oset obj value nil)
    (funcall (oref obj reader)
             (oref obj prompt))))

(cl-defmethod transient-infix-read ((obj magit--git-variable:urls))
  (mapcar (lambda (url)
            (if (string-prefix-p "~" url)
                (expand-file-name url)
              url))
          (completing-read-multiple (oref obj prompt)
                                    nil nil nil
                                    (when-let ((values (oref obj value)))
                                      (mapconcat #'identity values ",")))))

(cl-defmethod transient-infix-read ((obj magit--git-variable:choices))
  (let ((choices (oref obj choices)))
    (when (functionp choices)
      (setq choices (funcall choices)))
    (if-let ((value (oref obj value)))
        (cadr (member value choices))
      (car choices))))

(cl-defmethod transient-infix-set ((obj magit--git-variable) value)
  (let ((variable (oref obj variable)))
    (oset obj value value)
    (if (oref obj multival)
        (magit-set-all value variable)
      (magit-set value variable))
    ;; TODO
    ;; (magit-refresh)
    ;; (message "%s %s" variable value)
    ))

(cl-defmethod transient-infix-set ((obj magit--git-variable:urls) values)
  (let ((previous (oref obj value))
        (seturl   (oref obj seturl-arg))
        (remote   (oref transient--prefix scope)))
    (oset obj value values)
    (dolist (v (-difference values previous))
      (magit-call-git "remote" "set-url" seturl "--add" remote v))
    (dolist (v (-difference previous values))
      (magit-call-git "remote" "set-url" seturl "--delete" remote
                      (concat "^" (regexp-quote v) "$")))
    (magit-refresh)))

;;;; Draw

(cl-defmethod transient-format-description ((obj magit--git-variable))
  (or (oref obj description)
      (oref obj variable)))

(cl-defmethod transient-format-value ((obj magit--git-variable))
  (if-let ((value (oref obj value)))
      (if (oref obj multival)
          (if (cdr value)
              (mapconcat (lambda (v)
                           (concat "\n     "
                                   (propertize v 'face 'transient-value)))
                         value "")
            (propertize (car value) 'face 'transient-value))
        (propertize (car (split-string value "\n"))
                    'face 'transient-value))
    (propertize "unset" 'face 'transient-inactive-value)))

(cl-defmethod transient-format-value ((obj magit--git-variable:choices))
  (let* ((variable (oref obj variable))
         (choices  (oref obj choices))
         (local    (magit-git-string "config" "--local"  variable))
         (global   (magit-git-string "config" "--global" variable))
         (default  (oref obj default))
         (fallback (oref obj fallback))
         (fallback (and fallback
                        (when-let ((val (magit-get fallback)))
                          (concat fallback ":" val)))))
    (when (functionp choices)
      (setq choices (funcall choices)))
    (concat
     (propertize "[" 'face 'transient-inactive-value)
     (mapconcat (lambda (choice)
                  (propertize choice 'face (if (equal choice local)
                                               'transient-value
                                             'transient-inactive-value)))
                choices
                (propertize "|" 'face 'transient-inactive-value))
     (and (or global fallback default)
          (concat
           (propertize "|" 'face 'transient-inactive-value)
           (cond (global
                  (propertize (concat "global:" global)
                              'face (cond (local
                                           'transient-inactive-value)
                                          ((member global choices)
                                           'transient-value)
                                          (t
                                           'font-lock-warning-face))))
                 (fallback
                  (propertize fallback
                              'face (if local
                                        'transient-inactive-value
                                      'transient-value)))
                 (default
                   (propertize (concat "default:" default)
                               'face (if local
                                         'transient-inactive-value
                                       'transient-value))))))
     (propertize "]" 'face 'transient-inactive-value))))

;;; Kludges

(defun magit--import-file-args (args files)
  (if files
      (cons (concat "-- " (mapconcat #'identity files ",")) args)
    args))

(defun magit--export-file-args (args)
  (let ((files (--first (string-prefix-p "-- " it) args)))
    (when files
      (setq args  (remove files args))
      (setq files (split-string (substring files 3) ",")))
    (list args files)))

;;; _
(provide 'magit-transient)
;;; magit-transient.el ends here

