TEX = main
PDF = $(TEX).pdf

.PHONY: all clean

all: $(PDF)

# LaTeX is single-pass: it can only use info written by a previous run.
# Pass 1: compile document, write cited keys to .aux
# bibtex: read .aux, resolve keys against .bib, produce .bbl
# Loop: re-run pdflatex until .aux stabilizes (cross-references settle).
#        Caps at 5 iterations to avoid runaway loops.
$(PDF): $(TEX).tex references.bib
	pdflatex $(TEX)
	bibtex $(TEX)
	@n=0; \
	while [ $$n -lt 5 ]; do \
		cp $(TEX).aux $(TEX).aux.prev; \
		pdflatex $(TEX); \
		if cmp -s $(TEX).aux $(TEX).aux.prev; then break; fi; \
		n=$$((n + 1)); \
	done; \
	rm -f $(TEX).aux.prev

clean:
	rm -f $(TEX).{aux,bbl,blg,log,out,synctex.gz,fls,fdb_latexmk,toc,lof,lot,nav,snm,vrb,pdf}
