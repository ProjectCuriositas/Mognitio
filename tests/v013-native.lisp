(in-package #:mognitio.tests)

(defun v13-native-code (body &optional (extra "") options)
  (multiple-value-bind (out err code) (process-result (list (namestring (v12-native (v13-manifest body extra) options))))
    (same "" out) (same "" err) code))

(deftest v013-native-basics
  (replacing (v13-host-code #'v13-native-code)
    (v013-host-join-and-first-class)
    (v013-host-create-and-entries)
    (v013-host-collision-and-subject)))

(deftest v013-native-growth-sort-gc
  (let* ((root (v13-directory)) (count 180)
         (names (loop for i below count collect (format nil "name-~3,'0D-~A" i (if (evenp i) "日" "😀")))))
    (dolist (name (reverse names)) (put-text (pathname (concatenate 'string root "/" name)) name))
    (let ((body (format nil "let expected:List<String>=List<String>[~{~S~^,~}];let kept:String=\"kept\"+\"!\";var iteration:Int=0;loop while(iteration<3){branch on readDirectory(~S){Result<List<DirectoryEntry>,IoError>::Err(error:IoError)=>panic{error->subject},Result<List<DirectoryEntry>,IoError>::Ok(entries:List<DirectoryEntry>)=>{assert entries->length()==~D;var i:Int=0;loop over(entries as entry:DirectoryEntry){assert branch on expected->at(i){Result<String,IndexError>::Ok(name:String)=>name==entry->name,Result<String,IndexError>::Err=>false};i=i+1;};}};iteration=iteration+1;};assert kept==\"kept!\";0" names root count)))
      (same 0 (v13-native-code body "" '(:arena-unit 4096 :cap 65536 :stress t :validate t))))))
