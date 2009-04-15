;;; ga.el --- Generic apt alike interfaces for various package management tools

;; Copyright (C) 2008, 2009 William Xu

;; Author: William Xu <william.xwl@gmail.com>
;; Version: 0.3

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
;; MA 02110-1301, USA.

;;; Commentary:

;; This extenstion tries to provide a generic apt(as used in Debian
;; GNU/Linux) alike interface over various package management tools,
;; such as: apt-get(Debian GNU/Linux), yum(redhat/fedora), emerge(Gentoo
;; GNU/Linux), fink(Mac OS X), pkg-get(Solaris), etc.

;; Put ga files into your load-path first.  Then add something similar
;; to the following example to your .emacs.  192.168.1.20 is a remote debian
;; machine, while localhost is a Mac OS X with fink installed.
;;
;;     ;; Add this so that we can edit file on remote machine as root.  Also
;;     ;; note that you should config your ssh agent not to prompt password
;;     ;; while logining the remote host.
;;
;;     (eval-after-load 'tramp
;;       '(progn
;;          (add-to-list 'tramp-default-proxies-alist
;;     		  '("192.168.1.20" "\\`root\\'" "/ssh:%h:"))
;;          ))
;;
;;     (require 'ga)
;;     (setq ga-backend-methods
;;           '((apt-get "ssh 192.168.1.20 sudo apt-get")
;;             (fink "sudo fink")))
;;
;; Then type: `M-x ga'.

;;; Code:

(require 'tramp)
(eval-when-compile
  (require 'cl))

;;; Customizations

(defgroup ga nil
  "Generic apt alike interfaces for various package management tools."
  :group 'ga)

(defcustom ga-mode-hook nil
  "Normal hook run after entering `ga-mode'."
  :type 'hook
  :group 'ga)

;; (defcustom ga-source-download-dir "~/download"
;;   "Directory for saving source downloads."
;;   :type 'string
;;   :group 'ga)

(defcustom ga-cache-filename "~/.ga-cache.el"
  "Ga cache file."
  :type 'string
  :group 'ga)

(defcustom ga-backend-methods '((apt-get "sudo apt-get")
                               (fink "sudo fink"))
  "Package management tool lists.
Each element is the essential command prefix string.  For
example, \"ssh foo sudo apt-get\".  Then the command will execute
as: \"$ ssh foo sudo apt-get ...\""
  :type 'list
  :group 'ga)

(defcustom ga-backend-list '(apt-get fink)
  "Supported backend list."
  :type 'list
  :group 'ga)

(defvar ga-backend nil)
(make-variable-buffer-local 'ga-backend)

(defvar ga-command "")
(make-variable-buffer-local 'ga-command)

(defvar ga-buffer-name "")
(make-variable-buffer-local 'ga-buffer-name)

(defvar ga-available-pkgs '())
(make-variable-buffer-local 'ga-available-pkgs)

(defvar ga-font-lock-keywords nil
  "Keywords to highlight in ga mode.")
(make-variable-buffer-local 'ga-font-lock-keywords)

(defvar ga-sources-file ""
  "Config file for the package management tool.")
(make-variable-buffer-local 'ga-sources-file)


;;; Ga Mode

(defvar ga-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Already defined for all backends.
    (define-key map "h" 'ga-help)
    (define-key map "I" 'ga-install-at-point)
    (define-key map "
    (define-key map "n" 'next-line)
    (define-key map "p" 'previous-line)
    (define-key map "K" 'ga-kill)
    (define-key map "E" 'ga-edit-sources)

    ;; RFC for each backend.
    (define-key map "u" 'ga-update)
    (define-key map "s" 'ga-search-by-name)
    (define-key map "S" 'ga-search)
    (define-key map "o" 'ga-show)
    (define-key map "i" 'ga-install)
    (define-key map "l" 'ga-listfiles)
    (define-key map "U" 'ga-upgrade)
    (define-key map "C" 'ga-clean)
    (define-key map "R" 'ga-remove)
    map)
  "Keymap for `ga-mode'.")

(defvar ga-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?- "w" st)
    st)
  "Syntax table used while in `ga-mode'.")

(define-derived-mode ga-mode nil "Generic apt-get"
  "Major mode for generic apt alike interfaces for various package management tools.
\\{ga-mode-map}"
  (set-syntax-table ga-mode-syntax-table)
  (setq font-lock-defaults '(ga-font-lock-keywords))
  (setq buffer-read-only t)

  ;; Take special care with these two!
  (setq ga-command ga-command)
  (setq ga-buffer-name ga-buffer-name)

  (setq ga-backend
        (let ((methods ga-backend-methods)
              (i nil)
              (ret nil))
          (while methods
            (setq i (car methods)
                  methods (cdr methods))
            (when (string= ga-command (cadr i))
              (setq ret (car i)
                    methods nil)))
          ret))

  (unless (memq ga-backend ga-backend-list)
    (error "Backend %S is not supported" 'ga-backend))

  ;; Load ga-BACKEND.el.
  (require (intern (concat "ga-" (downcase (symbol-name ga-backend)))))

  (setq ga-font-lock-keywords
        (intern (format "ga-%S-font-lock-keywords" ga-backend)))

  (setq ga-sources-file
        (eval (intern (format "ga-%S-sources-file" ga-backend))))

  (if (file-readable-p ga-cache-filename)
      (load-file ga-cache-filename)
    (ga-update-cache))

  (setq ga-available-pkgs
        (eval (intern (format "ga-%S-available-pkgs" ga-backend))))

  (run-hooks 'ga-mode-hook)
  (ga-help))

;;;###autoload
(defun ga (&optional method)
  "Create or switch to a ga buffer."
  (interactive)
  ;; Wrap around them so that even when current buffer is another
  ;; ga buffer, we won't mess with its local variables.
  (let* ((ga-command
          (or method
              (ido-completing-read "ga: "
                                   (mapcar (lambda (i) (cadr i))
                                           ga-backend-methods))))
         (ga-buffer-name
          (format "*Ga/%s*" ga-command)))
    (switch-to-buffer ga-buffer-name)
    (unless (eq major-mode 'ga-mode)
      (ga-mode))))


;;; Interfaces

(defun ga-help ()
  "Help page for `ga-mode'."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert
     "Welcome to generic apt -- The apt-get with *super* power!

Here is a brief list of the most useful commamnds:

    u - Selfupdate package database cache
    s - Search packages by name
    S - Search packages by content
    o - Describe a package
    i - Install a package
    l - List installed files by a package
    U - Upgrade a package
    R - Remove a package
    C - Cleanup
    E - Edit config file

------------- done --------------
")
    (message "For a list of all available commands, press `F1 m'.")))

(defun ga-edit-sources ()
  "Edit /etc/apt/sources.list using sudo, with `tramp' when necessary."
  (interactive)
  (let ((f ga-sources-file))
    (if (string-match "^ssh" ga-command)
        (let ((hostname "")
              (proxies tramp-default-proxies-alist)
              (i '()))
          (while proxies
            (setq i (car proxies)
                  proxies (cdr proxies))
            (when (string-match (regexp-opt (list (car i)))
                                ga-command)
              (setq hostname (car i)
                    f (format "/ssh:%s:%s" hostname f))
              (setq proxies nil)))
          (find-file f))
      (find-file (concat "/sudo::" f)))))

(defun ga-search (pkg)
  "Search PKG by package name."
  (interactive "sSearch: ")
  (funcall (ga-find-backend-function ga-backend 'search) pkg))

(defun ga-search-by-name (pkg)
  "Search PKG by package name, `-n'."
  (interactive "sSearch(by name): ")
  (funcall (ga-find-backend-function ga-backend 'search-by-name) pkg))

(defun ga-update ()
  "Update package database cache."
  (interactive)
  (funcall (ga-find-backend-function ga-backend 'update)))

(defun ga-install (pkg)
  "Install PKG."
  (interactive
   (list
    (ido-completing-read "Install: " ga-available-pkgs)))
  (funcall (ga-find-backend-function ga-backend 'install) pkg))

(defun ga-install-at-point ()
  "Install package at point."
  (interactive)
  (funcall (ga-find-backend-function ga-backend 'install-at-point)
           (current-word)))

(defun ga-upgrade (pkg)
  "Upgrade PKG."
  (interactive
   (list
    (ido-completing-read "Upgrade: " ga-available-pkgs)))
  (funcall (ga-find-backend-function ga-backend 'upgrade) pkg))

(defun ga-remove (pkg)
  "Remove PKG."
  (interactive
   (list
    (ido-completing-read "Remove: " ga-available-pkgs)))
  (funcall (ga-find-backend-function ga-backend 'remove) pkg))

(defun ga-show (pkg)
  "Describe PKG."
  (interactive
   (list
    (ido-completing-read "Show: " ga-available-pkgs)))
  (funcall (ga-find-backend-function ga-backend 'show) pkg))

(defun ga-show-at-point ()
  "Run `ga show' on current word(pkg name)."
  (interactive)
  (funcall (ga-find-backend-function ga-backend 'show-at-point)
           (current-word)))

(defun ga-upgrade-all ()
  "Upgrade all installed packages."
  (interactive)
  (funcall (ga-find-backend-function ga-backend 'upgrade-all)))

(defun ga-listfiles (pkg)
  "List files installed by PKG."
  (interactive
   (list
    (ido-completing-read "Listfiles: " ga-available-pkgs)))
  (funcall (ga-find-backend-function ga-backend 'listfiles) pkg))

(defun ga-clean ()
  "Clean cache."
  (interactive)
  (funcall (ga-find-backend-function ga-backend 'clean)))


;;; Internal Functions, Buffer, Process Management

(defvar ga-process nil)
(make-variable-buffer-local 'ga-process)

(defvar ga-running nil)
(make-variable-buffer-local 'ga-running)

(defun ga-update-cache ()
  "Update ga cache saved in `ga-cache-filename'."
  (interactive)
  (message "Updating ga cache...")
  (funcall (ga-find-backend-function ga-backend 'update-available-pkgs))
  (let ((backend ga-backend)
        (pkgs ga-available-pkgs))
    (with-temp-buffer
      (if (and (not (string= ga-cache-filename ""))
               (file-readable-p ga-cache-filename))
          (insert-file-contents ga-cache-filename)
        (insert ";;; automatically generated by ga, edit with care!!\n\n"))
      (goto-char (point-min))
      (let ((str-name (format "ga-%S-available-pkgs" backend)))
        (if (re-search-forward (format "(setq %s" str-name) nil t 1)
            (progn
              (backward-up-list)
              (kill-sexp))
          (goto-char (point-max)))
        (insert (format "(setq %s '%S)\n\n" str-name pkgs)))
      (write-region (point-min) (point-max) ga-cache-filename))
    (message "Updating ga cache...done")))

(defun ga-process-sentinel (process event)
  "Set buffer read-only after a ga command finishes."
  (with-current-buffer (process-buffer process)
    (save-excursion
      (setq ga-running nil)
      (let ((inhibit-read-only t))
        (cond
         ((eq (process-status process) 'exit)
          (goto-char (point-max))
          (insert "------------- done --------------\n"))
         ((eq (process-status process) 'signal)
          (message "ga process killed")))))))

(defun ga-process-filter (process output)
  "Filter ga command outputs."
  (with-current-buffer (process-buffer process)
    (let ((moving (= (point) (process-mark process)))
	  (inhibit-read-only t)
	  (percentage-match "[0-9]\\{1,3\\}%"))
      (save-excursion
	(goto-char (process-mark process))
	(setq output
              (replace-regexp-in-string "\r" "\n" output))
	;; make percentage output nicer
;;         (cond ((string-match percentage-match output)
;;                (message "ga: %s" output))
;;               ((string-match "^\\ +$\\|^\n$" output)
;;                nil)
;;               (t
;;                (forward-line 0)
;; ;;                (insert output)))
        (insert output)
	(set-marker (process-mark process) (point)))
      (and moving (goto-char (process-mark process))))))

(defun ga-kill ()
  "Kill ga process."
  (interactive)
  (when ga-process
    (unless (eq (process-status ga-process) 'exit)
      (delete-process ga-process))
    (setq ga-running nil)))

(defun ga-run-command (args)
  (ga-run-1 (append (split-string ga-command " ") args)))

(defun ga-run-command-to-string (args-string)
  (shell-command-to-string (concat ga-command " " args-string)))

(defun ga-run-other-command (other-cmd-and-args)
  (ga-run-1
   (append (split-string (ga-extract-prefix)) other-cmd-and-args)))

(defun ga-run-other-command-to-string (other-cmd-and-args-string)
  (shell-command-to-string
   (concat (ga-extract-prefix) " " other-cmd-and-args-string)))

(defun ga-extract-prefix ()
  "Extract prefix from `ga-command'.

For instance, \"sudo fink\" => \"sudo\""
  (replace-regexp-in-string " ?[^ ]+$" "" ga-command))

(defun ga-run-1 (full-command-and-args)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if ga-running
        (error "Ga process already exists")
      (setq ga-running t)
      (setq ga-process
            (apply 'start-process "ga" ga-buffer-name
                   full-command-and-args))
      (set-process-filter ga-process 'ga-process-filter)
      (set-process-sentinel ga-process 'ga-process-sentinel))))

(defun ga-find-backend-function (backend fun)
  "Find ga-BACKEND-FUN."
  (let ((f (intern (format "ga-%S-%S" backend fun))))
    (if (fboundp f)
        f
      ;; ;; Load ga-BACKEND.el if needed.
      ;; (require (intern (concat "ga-" (downcase (symbol-name backend)))))
      ;; (if (fboundp f)
      ;;   f
      (error "Sorry, %S is not implemented for %S" f backend))))


;;; Compatibility

;; (defalias 'ga-completing-read
;;   (if (and (fboundp 'ido-completing-read)
;; 	   ido-mode)
;;       'ido-completing-read		; added in Emacs 22
;;     'completing-read))


(provide 'ga)

;;; ga.el ends here