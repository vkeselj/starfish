sourcedir=../../testfiles/22-hooks
outrsource=../../testfiles/22-hooks/text-replace.out
outr=text-replace.out
help:
	@echo '# Makefile for test 22-hooks'
	@echo '# It is not required for testing, so it does not have to work.'
	@echo '# It is used for development'
	@echo make
	@echo '	em1	emacs input and replace-output for checking'
	@echo '	cp-back-or	copy replace-output to source'
	@echo '	cp-back-m	copy Makefile to source'

.PHONY: help em1 cp-back-or cp-back-m
em1:; emacs -nw text.in text-replace.out
cp-back-or:; cp ${outr} ${outrsource}
cp-back-m:; cp Makefile ${sourcedir}/


