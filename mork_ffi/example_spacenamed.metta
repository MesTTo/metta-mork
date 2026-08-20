;Named MORK spaces and bulk ingestion. &mork is the default space;
;&mork:<name> is its own store inside MORK, created on first use, and
;(mork-add-atoms <space> <atoms>) lands a whole list in one FFI call.

!(import! &self ../lib/lib_mm2)

!(add-atom &mork:left (side l))
!(add-atom &mork:right (side r))
!(test (collapse (match &mork:left (side $x) $x)) (l))
!(test (collapse (match &mork:right (side $x) $x)) (r))

!(mork-add-atoms &mork:left ((bulk 1) (bulk 2) (bulk 3)))
!(test (length (collapse (match &mork:left (bulk $n) $n))) 3)

;The default space through lib_mm2's sugar, bulk included:
!(＋* ((pair a 1) (pair b 2)))
!(test (length (collapse (? (pair $k $v) ($k $v)))) 2)
