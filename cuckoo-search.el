;;; cuckoo-search.el --- Content-based search hacks for elfeed -*- lexical-binding: t; -*-

;; Maintainer: René Trappel <rtrappel@gmail.com>
;; URL: https://github.com/rtrppl/cuckoo-search
;; Version: 0.2
;; Package-Requires: ((emacs "27.2"))
;; Keywords: comm wp outlines

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; cuckoo-search.el is collection of hacks to allow for content-based 
;; search in elfeed. Very early stage. Requires ripgrep.
;;
;;
;;
;;; News
;;
;; 0.2
;; - Added `cuckoo-saved-searches'
;;
;; 0.1
;; - Initial release

(require 'json)   ; For json-encode

(defvar cuckoo-search-content-id (make-hash-table :test 'equal) "Hashtable with the key content hash and the value id.")
(defvar cuckoo-search-elfeed-data-folder "~/.elfeed/data/")
(defvar cuckoo-search-elfeed-index-file "~/.elfeed/index")
(defvar cuckoo-search-rg-cmd "rg -l -i -e")
(defvar cuckoo-saved-searches-config-file "~/.cuckoo-search-saved-searches")

(defun cuckoo-search-read-index-file ()
  "Reads the Elfeed index file and returns only the real index (:version 4)."
  (with-temp-buffer
    (insert-file-contents cuckoo-search-elfeed-index-file) 
    (goto-char (point-min))
    (let (real-index)  
      (while (not (eobp))  
        (condition-case nil 
            (let ((data (read (current-buffer))))  
              (when (and (plistp data) (= (plist-get data :version) 4))
                (setq real-index data)))
          (error nil)))  
      real-index))) 

(defun cuckoo-search-get-index-meta ()
  "Parses the index and fills the hashtable `cuckoo-search-content-id'."
  (let ((index (cuckoo-search-read-index-file)) 
        (entries nil))
    (when index 
      (setq entries (plist-get index :entries)) 
      (if entries  
          (maphash (lambda (key value)
		      (let* ((entry-content (elfeed-entry-content value))
			     (entry-string (prin1-to-string entry-content))  
			     (entry-content-hash 
			      (if 
				  (string-match "\"\\([a-f0-9]+\\)\"" entry-string)
				  (match-string 1 entry-string)
				nil)))
			(puthash entry-content-hash value cuckoo-search-content-id)))
		       entries)))))

(defun cuckoo-search (&optional search-string)
 "Content-based search for Elfeed."
 (interactive)
 (cuckoo-search-get-index-meta)
 (let* ((search (if (not search-string)
			 (read-from-minibuffer "Search for: ")
		       search-string))
	(cuckoo-search-findings-content-id (make-hash-table :test 'equal)))
   (with-temp-buffer
     (insert (shell-command-to-string (concat cuckoo-search-rg-cmd " \"" search "\" \"" (expand-file-name cuckoo-search-elfeed-data-folder) "\" --sort accessed")))
      (let ((lines (split-string (buffer-string) "\n" t)))
	(dolist (content lines)
	  (puthash (file-name-nondirectory content) (gethash (file-name-nondirectory content) cuckoo-search-content-id) cuckoo-search-findings-content-id))))
   (with-current-buffer "*elfeed-search*"
     (let* ((allowed-entries (hash-table-values cuckoo-search-findings-content-id)) 
	    (filtered-entries '())) 
       (dolist (entry elfeed-search-entries)
	 (when (member entry allowed-entries)
	   (push entry filtered-entries))) 
       (setq elfeed-search-entries (nreverse filtered-entries)) 
         (let ((inhibit-read-only t)
              (standard-output (current-buffer)))
           (erase-buffer)
           (dolist (entry elfeed-search-entries)
             (funcall elfeed-search-print-entry-function entry)
             (insert "\n"))
	   (setq header-line-format
		 (list (elfeed-search--header) " \"" search "\""))
           (setf elfeed-search-last-update (float-time)))))))

(advice-add 'elfeed-search-clear-filter :after #'cuckoo-search-elfeed-restore-header)

(defun cuckoo-search-elfeed-restore-header ()
 "Restores the old `header-line-format'."
(with-current-buffer "*elfeed-search*"
  (setq header-line-format (elfeed-search--header))))     

(defun cuckoo-search-add-search ()
  "Adds a new search combo to the list of searches."
  (interactive)
  (let* ((cuckoo-search-list-searches (cuckoo-search-get-list-of-searches))
	 (elfeed-search-string (read-from-minibuffer "Enter the Elfeed-search-string to use (e.g. @6-months-ago +unread): "))
	 (cuckoo-search-string (read-from-minibuffer "Enter the cuckoo-search-string to use (e.g. -w China): "))
	 (search-name (read-from-minibuffer "Please provide a name for the new stream: "))
	 (search-name (replace-regexp-in-string "[\"'?:;\\\/]" "_" search-name)))
    (when (not cuckoo-search-list-searches)
      (setq cuckoo-search-list-searches (make-hash-table :test 'equal)))
    (puthash search-name (concat elfeed-search-string "::" cuckoo-search-string) cuckoo-search-list-searches)
    (with-temp-buffer
      (let* ((json-data (json-encode cuckoo-search-list-searches)))
	(insert json-data)
	(write-file cuckoo-saved-searches-config-file)))))

(defun cuckoo-search-get-list-of-searches ()
 "Return cuckoo-search-name-search, a hashtable that includes a list of names and locations of all searches."
 (let ((cuckoo-search-file-exists (cuckoo-search-check-for-search-file)))
   (when cuckoo-search-file-exists
     (let ((cuckoo-search-list-searches (make-hash-table :test 'equal)))
       (with-temp-buffer
	 (insert-file-contents cuckoo-saved-searches-config-file)
	 (if (fboundp 'json-parse-buffer)
	     (setq cuckoo-search-list-searches (json-parse-buffer))))
cuckoo-search-list-searches))))

(defun cuckoo-search-check-for-search-file ()
  "Checks for a search file in `cuckoo-saved-searches-config-file'."
  (let ((cuckoo-search-file-exists nil)
	(cuckoo-search-list-searches (make-hash-table :test 'equal))
	(length-of-list))
  (when (file-exists-p cuckoo-saved-searches-config-file)
    (with-temp-buffer
	 (insert-file-contents cuckoo-saved-searches-config-file)
	 (if (fboundp 'json-parse-buffer)
	     (setq cuckoo-search-list-searches (json-parse-buffer)))
	 (setq length-of-list (length (hash-table-values cuckoo-search-list-searches)))
	 (when (not (zerop length-of-list))
	   (setq cuckoo-search-file-exists t))))
  cuckoo-search-file-exists))

(defun cuckoo-search-saved-searches ()
  "Start a search from the list."
  (interactive)
  (let* ((cuckoo-search-list-searches (cuckoo-search-get-list-of-searches))
	 (searches (hash-table-keys cuckoo-search-list-searches))
	 (selection (completing-read "Select search: " searches))
	 (elfeed-string (cuckoo-search-get-elfeed-string selection))
	 (cuckoo-string (cuckoo-search-get-cuckoo-string selection)))
    (with-current-buffer "*elfeed-search*"
      (when (not (string= elfeed-string ""))
	(setq elfeed-search-filter elfeed-string)
	(elfeed-search-update--force))
	(cuckoo-search-elfeed-restore-header))
      (when (not (string= cuckoo-string ""))
	(cuckoo-search cuckoo-string))))

(defun cuckoo-search-get-elfeed-string (string)
  "Return the elfeed-search-string."
 (let* ((cuckoo-search-list-searches (cuckoo-search-get-list-of-searches))
       (elfeed-string (gethash string cuckoo-search-list-searches)))
   (string-match "\\(.*?\\)::\\(.*\\)" elfeed-string)
   (setq elfeed-string (match-string 1 elfeed-string))
   elfeed-string))

(defun cuckoo-search-get-cuckoo-string (string)
   "Return the cuckoo-search-string."
  (let* ((cuckoo-search-list-searches (cuckoo-search-get-list-of-searches)) 
	 (cuckoo-string (gethash string cuckoo-search-list-searches)))
   (string-match "\\(.*?\\)::\\(.*\\)" cuckoo-string)
   (setq cuckoo-string (match-string 2 cuckoo-string))
   cuckoo-string))
	 
(defun cuckoo-search-remove-search ()
  "Remove a search from the list."
  (interactive)
  (let* ((cuckoo-search-list-searches (cuckoo-search-get-list-of-searches))
	 (searches (hash-table-keys cuckoo-search-list-searches))
	 (json-data)
	 (selection))
    (sort searches 'string<)
    (setq selection
	  (completing-read "Which search should be removed? " searches))
    (if (not (member selection searches))
	(message "This search does not exist.")
      (if (yes-or-no-p (format "Are you sure you want to remove \"%s\" as a saved search? " selection))
	  (progn
	    (remhash selection cuckoo-search-list-searches)
	    (with-temp-buffer
	      (setq json-data (json-encode cuckoo-search-list-searches))
	      (insert json-data)
	      (write-file cuckoo-saved-searches-config-file)))))))

(provide 'cuckoo-search)
