;;; errand.el --- Run Claude Code errands on workers -*- lexical-binding: t; -*-

;; Copyright (C) 2026  David Álvarez Rosa

;; Author: David Álvarez Rosa <david@alvarezrosa.com>
;; Maintainer: David Álvarez Rosa <david@alvarezrosa.com>
;; URL: https://github.com/david-alvarez-rosa/errand
;; Version: 1.1.0
;; Package-Requires: ((emacs "29.1") (ghostel "0.52.0"))
;; Keywords: tools, vc
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `errand-agents' opens Claude's agent view for a project.el project
;; on this machine or on an SSH host.  Each host is a Git remote named
;; `errand-HOST': the current commit is pushed to it and its agents'
;; branches are fetched back.
;;
;; A remote worker needs git, python3, rsync and Claude Code, with
;; CLAUDE_CONFIG_DIR set.

;;; Code:

(require 'project)

(declare-function ghostel-create "ghostel")
(defvar ghostel-shell)
(defvar ghostel-kill-buffer-on-exit)

(defgroup errand nil
  "Run Claude Code errands on workers."
  :group 'tools)

(defcustom errand-workers '("local")
  "Workers that can run errands, the first being the default.
\"local\" is this machine; any other name is an SSH host."
  :type '(repeat string))

(defcustom errand-directory "dev"
  "Directory under the remote home that holds one clone per project."
  :type 'string)

(defcustom errand-claude "~/.local/bin/claude"
  "Claude Code executable, at the same path on every worker."
  :type 'string)

(defcustom errand-claude-args '("--dangerously-skip-permissions")
  "Extra arguments for the agent view."
  :type '(repeat string))

(defconst errand--start-branch "errand-start"
  "Branch on a worker that receives the current commit.")

(defconst errand--settings "{\"worktree\":{\"baseRef\":\"head\"}}"
  "Claude settings making agents branch from the checked out commit.")

(defconst errand--setup-script
  "set -eu
dir=$HOME/$1
mkdir -p \"$dir/.git/lfs/objects\"
test -e \"$dir/.git/HEAD\" || git -C \"$dir\" init -q
git -C \"$dir\" config receive.denyCurrentBranch updateInstead
python3 - \"$CLAUDE_CONFIG_DIR/.claude.json\" \"$dir\" <<'EOF'
import json, os, sys
path, dir = sys.argv[1:]
try:
    with open(path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
project = config.setdefault('projects', {}).setdefault(dir, {})
if not project.get('hasTrustDialogAccepted'):
    project['hasTrustDialogAccepted'] = True
    with open(path + '.errand', 'w') as f:
        json.dump(config, f, indent=2)
    os.replace(path + '.errand', path)
EOF"
  "Shell script creating the clone named by $1 and trusting it in Claude.")

(defun errand--root ()
  "Return the root of the current local project."
  (let ((root (project-root (project-current t))))
    (when (file-remote-p root)
      (user-error "Errand needs a local project"))
    root))

(defun errand--name (root)
  "Return the project name for ROOT."
  (file-name-nondirectory (directory-file-name (expand-file-name root))))

(defun errand--dir (name)
  "Return the directory of project NAME on a remote worker."
  (format "%s/%s" errand-directory name))

(defun errand--local-p (worker)
  "Return non-nil if WORKER is this machine."
  (equal worker "local"))

(defun errand--remote (worker)
  "Return the name of the Git remote for WORKER."
  (format "errand-%s" worker))

(defun errand--read-worker (prompt)
  "Return the default worker, or read one if PROMPT is non-nil."
  (cond ((null errand-workers) (user-error "No errand workers configured"))
        ((and prompt (cdr errand-workers))
         (completing-read "Worker: " errand-workers nil t))
        (t (car errand-workers))))

(defun errand--git (&rest args)
  "Run Git with ARGS and return its output lines."
  (apply #'process-lines-ignore-status "git" args))

(defun errand--check (root)
  "Signal an error unless ROOT is inside a Git work tree."
  (unless (eq 0 (call-process "git" nil nil nil "rev-parse" "--is-inside-work-tree"))
    (user-error "Not a Git repository: %s" root)))

(defun errand--ensure-remote (worker name)
  "Point the Git remote for WORKER at its clone of project NAME."
  (let ((remote (errand--remote worker)))
    (errand--git "config" (format "remote.%s.url" remote)
                 (format "%s:%s" worker (errand--dir name)))
    (errand--git "config" (format "remote.%s.fetch" remote)
                 (format "+refs/heads/worktree-*:refs/remotes/%s/worktree-*" remote))))

(defun errand--agents-command ()
  "Return the shell command opening Claude's agent view."
  (mapconcat
   #'identity
   `("exec" ,errand-claude "agents" "--cwd" "."
     "--settings" ,(shell-quote-argument errand--settings)
     ,@(mapcar #'shell-quote-argument errand-claude-args))
   " "))

(defun errand--ssh (worker flags remote-command)
  "Return a shell command running REMOTE-COMMAND on WORKER.
FLAGS is a string of extra ssh flags."
  (format "ssh %s%s %s" flags (shell-quote-argument worker)
          (shell-quote-argument remote-command)))

(defun errand--sync-command (worker name)
  "Return a shell command syncing project NAME with WORKER.
It sends HEAD to WORKER and fetches its agents' branches."
  (let ((dir (shell-quote-argument (errand--dir name)))
        (remote (shell-quote-argument (errand--remote worker))))
    (format "%s && git push -q --no-verify -f %s HEAD:refs/heads/%s && %s && %s && git fetch -q --prune %s"
            (errand--ssh worker "" (format "sh -c %s errand %s"
                                           (shell-quote-argument errand--setup-script) dir))
            remote errand--start-branch
            (format "lfs=$(git rev-parse --git-common-dir)/lfs/objects && { ! test -d \"$lfs\" || rsync -a \"$lfs/\" %s; }"
                    (shell-quote-argument
                     (format "%s:%s/.git/lfs/objects/" worker (errand--dir name))))
            (errand--ssh worker "" (format "git -C %s checkout -q --detach %s"
                                           dir errand--start-branch))
            remote)))

(defun errand--live-p (buffer-name)
  "Return non-nil if the process of BUFFER-NAME is live."
  (when-let* ((buffer (get-buffer buffer-name)))
    (process-live-p (get-buffer-process buffer))))

(defun errand--terminal (buffer-name command)
  "Run shell COMMAND in a fresh terminal named BUFFER-NAME."
  (require 'ghostel)
  (when-let* ((buffer (get-buffer buffer-name)))
    (kill-buffer buffer))
  (let ((ghostel-shell (list "sh" "-c" (concat command " || echo 'errand: failed'"))))
    (with-current-buffer (ghostel-create buffer-name '((display-buffer-same-window)))
      ;; Keep a failed run readable.
      (setq-local ghostel-kill-buffer-on-exit nil))))

(defun errand--sync-in-background (worker name)
  "Sync project NAME with WORKER without blocking."
  (make-process
   :name "errand-sync" :noquery t :connection-type 'pipe :buffer " *errand-sync*"
   :command (list "sh" "-c" (errand--sync-command worker name))
   :sentinel (lambda (process _)
               (when (memq (process-status process) '(exit signal))
                 (unless (eq 0 (process-exit-status process))
                   (message "Errand: sync with %s failed, see buffer \" *errand-sync*\""
                            worker))))))

;;;###autoload
(defun errand-agents (&optional worker)
  "Open this project's agent view on WORKER.
WORKER defaults to the first of `errand-workers'; with a prefix
argument, prompt for one.  A remote worker first receives the current
commit, and its agents' branches are fetched."
  (interactive (list (errand--read-worker current-prefix-arg)))
  (let* ((default-directory (errand--root))
         (worker (or worker (errand--read-worker nil)))
         (local (errand--local-p worker))
         (name (errand--name default-directory))
         (buffer-name (format "*%s-errand@%s*" name worker)))
    (errand--check default-directory)
    (unless local
      (errand--ensure-remote worker name))
    (cond ((errand--live-p buffer-name)
           (unless local
             (errand--sync-in-background worker name))
           (pop-to-buffer-same-window buffer-name))
          (local
           (errand--terminal buffer-name (errand--agents-command)))
          (t
           (errand--terminal
            buffer-name
            (format "%s && %s"
                    (errand--sync-command worker name)
                    (errand--ssh worker "-t "
                                 (format "cd %s && %s"
                                         (shell-quote-argument (errand--dir name))
                                         (errand--agents-command)))))))))

(provide 'errand)
;;; errand.el ends here
