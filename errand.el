;;; errand.el --- Run Claude Code errands on a remote worker -*- lexical-binding: t; -*-

;; Author: David Álvarez Rosa
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ghostel "0"))
;; Keywords: tools, vc

;;; Commentary:

;; Delegate Claude Code sessions for a project.el project to a remote
;; worker and drive them from a ghostel terminal.  Their branches are
;; fetched through the `errand' Git remote.

;;; Code:

(require 'project)
(require 'subr-x)

(declare-function ghostel-create "ghostel")
(defvar ghostel-shell)
(defvar ghostel-kill-buffer-on-exit)

(defgroup errand nil
  "Run Claude Code errands on a remote worker."
  :group 'tools)

(defcustom errand-host "homelab"
  "SSH host that runs the errands."
  :type 'string)

(defcustom errand-directory "dev"
  "Directory under the remote home that holds one clone per project."
  :type 'string)

(defcustom errand-claude "~/.local/bin/claude"
  "Claude Code executable on the remote host."
  :type 'string)

(defcustom errand-claude-args '("--dangerously-skip-permissions")
  "Extra arguments for the remote agent view."
  :type '(repeat string))

(defconst errand--remote "errand")
(defconst errand--start-branch "errand-start")
(defconst errand--settings "{\"worktree\":{\"baseRef\":\"head\"}}")

(defconst errand--setup-script
  "set -eu
dir=$HOME/$1
mkdir -p \"$dir/.git/lfs/objects\"
test -e \"$dir/.git/HEAD\" || git -C \"$dir\" init -q")

(defun errand--root ()
  (let ((root (project-root (project-current t))))
    (when (file-remote-p root)
      (user-error "Errand needs a local project"))
    root))

(defun errand--name (root)
  (let ((root (expand-file-name root)))
    (format "%s-%s" (file-name-nondirectory (directory-file-name root))
            (substring (md5 root) 0 8))))

(defun errand--dir (name)
  (format "%s/%s" errand-directory name))

(defun errand--git (&rest args)
  (apply #'process-lines-ignore-status "git" args))

(defun errand--check (root)
  (unless (eq 0 (call-process "git" nil nil nil "rev-parse" "--is-inside-work-tree"))
    (user-error "Not a Git repository: %s" root)))

(defun errand--ensure-remote (name)
  (errand--git "config" (format "remote.%s.url" errand--remote)
               (format "%s:%s" errand-host (errand--dir name)))
  (errand--git "config" (format "remote.%s.fetch" errand--remote)
               (format "+refs/heads/worktree-*:refs/remotes/%s/*" errand--remote)))

(defun errand--warn-dirty ()
  (when (errand--git "status" "--porcelain")
    (message "Errand: uncommitted changes are not sent to %s" errand-host)))

(defun errand--agents-command (dir)
  (string-join
   `("cd" ,(shell-quote-argument dir) "&&"
     "exec" ,errand-claude "agents" "--cwd" "."
     "--settings" ,(shell-quote-argument errand--settings)
     ,@(mapcar #'shell-quote-argument errand-claude-args))
   " "))

(defun errand--ssh (flags remote-command)
  (format "ssh %s%s %s" flags (shell-quote-argument errand-host)
          (shell-quote-argument remote-command)))

(defun errand--sync-command (name)
  (let ((dir (shell-quote-argument (errand--dir name))))
    (format "%s && git push -q --no-verify -f %s HEAD:refs/heads/%s && %s && %s"
            (errand--ssh "" (format "sh -c %s errand %s"
                                    (shell-quote-argument errand--setup-script) dir))
            errand--remote errand--start-branch
            (format "lfs=$(git rev-parse --git-common-dir)/lfs/objects && { ! test -d \"$lfs\" || rsync -a \"$lfs/\" %s; }"
                    (shell-quote-argument
                     (format "%s:%s/.git/lfs/objects/" errand-host (errand--dir name))))
            (errand--ssh "" (format "git -C %s checkout -q --detach %s"
                                    dir errand--start-branch)))))

(defun errand--live-p (buffer-name)
  (when-let* ((buffer (get-buffer buffer-name)))
    (process-live-p (get-buffer-process buffer))))

(defun errand--terminal (buffer-name command)
  (require 'ghostel)
  (when-let* ((buffer (get-buffer buffer-name)))
    (kill-buffer buffer))
  (let ((ghostel-shell (list "sh" "-c" (concat command " || echo 'errand: failed'"))))
    (with-current-buffer (ghostel-create buffer-name '((display-buffer-same-window)))
      ;; Keep the dead buffer so a failure stays readable without
      ;; counting as a live session.
      (setq-local ghostel-kill-buffer-on-exit nil))))

(defun errand--sync-in-background (name)
  (make-process
   :name "errand-sync" :noquery t :connection-type 'pipe :buffer " *errand-sync*"
   :command (list "sh" "-c" (errand--sync-command name))
   :sentinel (lambda (process _)
               (when (memq (process-status process) '(exit signal))
                 (unless (eq 0 (process-exit-status process))
                   (message "Errand: sync to %s failed, see buffer \" *errand-sync*\""
                            errand-host))))))

;;;###autoload
(defun errand-agents ()
  "Send the current commit to the worker and open this project's dashboard."
  (interactive)
  (let* ((default-directory (errand--root))
         (name (errand--name default-directory))
         (buffer-name (format "*%s-errand*" name)))
    (errand--check default-directory)
    (errand--ensure-remote name)
    (errand--warn-dirty)
    (if (errand--live-p buffer-name)
        (progn (errand--sync-in-background name)
               (pop-to-buffer-same-window buffer-name))
      (errand--terminal
       buffer-name
       (format "%s && %s"
               (errand--sync-command name)
               (errand--ssh "-t " (errand--agents-command (errand--dir name))))))))

(provide 'errand)
;;; errand.el ends here
