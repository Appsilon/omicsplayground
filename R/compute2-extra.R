##
## This file is part of the Omics Playground project.
## Copyright (c) 2018-2020 BigOmics Analytics Sagl. All rights reserved.
##

##extra <- c("meta.go","deconv","infer","drugs")
##extra <- c("wordcloud")
EXTRA.MODULES = c("meta.go","deconv","infer","drugs",
                  "connectivity","graph","wordcloud")

compute.extra <- function(ngs, extra, lib.dir, sigdb=NULL) {
        
    timings <- c()

    extra <- intersect(extra, EXTRA.MODULES)
    if(length(extra)==0) {
        return(ngs)
    }
    
    ## detect if it is single or multi-omics
    single.omics <- !any(grepl("\\[",rownames(ngs$counts)))
    single.omics
    if(single.omics) {
        message(">>> computing extra for SINGLE-OMICS")
        rna.counts <- ngs$counts
    } else {
        message(">>> computing extra for MULTI-OMICS")
        data.type <- gsub("\\[|\\].*","",rownames(ngs$counts))
        jj <- which(data.type %in% c("gx","mrna"))
        length(jj)
        if(length(jj)==0) {
            stop("FATAL. could not find gx/mrna values.")
        }
        rna.counts <- ngs$counts[jj,]
        ##rownames(rna.counts) <- gsub(".*:|.*\\]","",rownames(rna.counts))
        is.logged <- ( min(rna.counts, na.rm=TRUE) < 0 ||
                       max(rna.counts, na.rm=TRUE) < 50 )
        if(is.logged) {
            message("expression data seems log. undoing logarithm")
            rna.counts <- 2**rna.counts
        }
    }

    if("meta.go" %in% extra) {
        message(">>> Computing GO core graph...")
        tt <- system.time({
            ngs$meta.go <- pgx.computeCoreGOgraph(ngs, fdr=0.20)
        })
        timings <- rbind(timings, c("meta.go", tt))
    }

    if("deconv" %in% extra) {
        message(">>> computing deconvolution")
        tt <- system.time({
            ngs <- compute.deconvolution(
                ngs, lib.dir=lib.dir, rna.counts=rna.counts,
                full=FALSE) 
        })
        timings <- rbind(timings, c("deconv", tt))
    }

    if("infer" %in% extra) {
        message(">>> inferring extra phenotypes...")
        tt <- system.time({
            ngs <- compute.cellcycle.gender(ngs, rna.counts=rna.counts)
        })
        timings <- rbind(timings, c("infer", tt))
    }

    if("drugs" %in% extra) {
        message(">>> Computing drug activity enrichment...")
        ngs$drugs <- NULL  ## reset??

        tt <- system.time({
            ngs <- compute.drugActivityEnrichment(ngs, lib.dir=lib.dir) 
        })
        timings <- rbind(timings, c("drugs", tt))

        message(">>> Computing drug sensitivity enrichment...")        
        tt <- system.time({
            ngs <- compute.drugSensitivityEnrichment(
                ngs, lib.dir=lib.dir, ref.db=c("CTRPv2","GDSC")) 
        })
        timings <- rbind(timings, c("drugs-sx", tt))

        if(1) {
            message(">>> Computing gene perturbation enrichment...")
            tt <- system.time({
                ngs <- compute.genePerturbationEnrichment(ngs, lib.dir=lib.dir)
            })
            timings <- rbind(timings, c("drugs-gene", tt))
        }

    }
    
    if("graph" %in% extra) {
        message(">>> computing OmicsGraphs...")
        tt <- system.time({
            ngs <- compute.omicsGraphs(ngs) 
        })
        timings <- rbind(timings, c("graph", tt))
    }
    
    if("wordcloud" %in% extra) {
        message(">>> computing WordCloud statistics...")
        tt <- system.time({
            res <- pgx.calculateWordFreq(ngs, progress=NULL, pg.unit=1)        
        })
        timings <- rbind(timings, c("wordcloud", tt))
        ngs$wordcloud <- res
        remove(res)
    }

    if("connectivity" %in% extra) {
        message(">>> computing connectivity scores...")

        ## ngs$connectivity <- NULL  ## clean up
        if(is.null(sigdb)) {
            ##sigdb <- dir(c(FILES,FILESX), pattern="sigdb-.*h5", full.names=TRUE)   
            lib.dir2 <- c(lib.dir, sub("lib$","libx",lib.dir))  ### NEED BETTER SOLUTION!!!
            lib.dir2 <- unique(lib.dir2)
            sigdb <- dir(lib.dir2, pattern="^sigdb-.*h5$", full.names=TRUE)
            sigdb
        }
        
        ## sigdb.list = c(
        ##     file.path(PGX.DIR,"datasets-allFC.csv"),
        ##     file.path(FILES,"sigdb-archs4.h5")
        ## )
        db <- sigdb[1]
        for(db in sigdb) {
            if(file.exists(db)) {
                ntop = 10000
                ntop = 1000
                message("computing connectivity scores for ",db)
                ## in memory for many comparisons
                meta = pgx.getMetaFoldChangeMatrix(ngs, what="meta")
                inmemory <- ifelse(ncol(meta$fc)>50,TRUE,FALSE) 
                inmemory
                tt <- system.time({
                    scores <- pgx.computeConnectivityScores(
                        ngs, db, ntop=ntop, contrasts=NULL,
                        remove.le=TRUE, inmemory=inmemory )
                })
                timings <- rbind(timings, c("connectivity", tt))
                
                db0 <- sub(".*/","",db)
                ngs$connectivity[[db0]] <- scores
                remove(scores)
            }
        }
        names(ngs$connectivity)        
    }

    ##------------------------------------------------------
    ## pretty collapse all timings
    ##------------------------------------------------------
    ##timings0 <- do.call(rbind, timings)
    timings <- as.matrix(timings)
    rownames(timings) <- timings[,1]
    timings0 <- apply(as.matrix(timings[,-1,drop=FALSE]),2,as.numeric)
    if(nrow(timings)==1) {
        timings0 <- matrix(timings0,nrow=1)
        colnames(timings0) <- colnames(timings)[-1]
        rownames(timings0) <- rownames(timings)
    }
    rownames(timings0) <- rownames(timings)
    timings0 <- apply( timings0, 2, function(x) tapply(x,rownames(timings0),sum))
    if(is.null(nrow(timings0))) {
        cn <- names(timings0)
        rn <- unique(rownames(timings))
        timings0 <- matrix(timings0, nrow=1)
        colnames(timings0) <- cn
        rownames(timings0) <- rn[1]
    }
    rownames(timings0) <- paste("[extra]",rownames(timings0))
    
    ngs$timings <- rbind(ngs$timings, timings0)
    
    return(ngs)
}


## -------------- deconvolution analysis --------------------------------
##lib.dir=FILES;rna.counts=ngs$counts;full=FALSE
compute.deconvolution <- function(ngs, lib.dir, rna.counts=ngs$counts, full=FALSE) {
    
    ## list of reference matrices
    refmat <- list()
    readSIG <- function(f) read.csv(file.path(lib.dir,f), row.names=1, check.names=FALSE)
    LM22 <- read.csv(file.path(lib.dir,"LM22.txt"),sep="\t",row.names=1)
    refmat[["Immune cell (LM22)"]] <- LM22
    refmat[["Immune cell (ImmProt)"]] <- readSIG("immprot-signature1000.csv")
    refmat[["Immune cell (DICE)"]] <- readSIG("DICE-signature1000.csv")
    refmat[["Immune cell (ImmunoStates)"]] <- readSIG("ImmunoStates_matrix.csv")
    refmat[["Tissue (HPA)"]] <- readSIG("rna_tissue_matrix.csv")
    refmat[["Tissue (GTEx)"]] <- readSIG("GTEx_rna_tissue_tpm.csv")
    refmat[["Cell line (HPA)"]] <- readSIG("HPA_rna_celline.csv")
    refmat[["Cell line (CCLE)"]] <- readSIG("CCLE_rna_celline.csv")
    refmat[["Cancer type (CCLE)"]] <- readSIG("CCLE_rna_cancertype.csv")

    ## list of methods to compute
    ##methods = DECONV.METHODS
    methods = c("DCQ","DeconRNAseq","I-NNLS","NNLM","cor","CIBERSORT","EPIC","FARDEEP")
    ##methods <- c("DCQ","DeconRNAseq","I-NNLS","NNLM","cor")
    methods <- c("DCQ","DeconRNAseq","I-NNLS","NNLM","cor")
    ##methods <- c("DCQ","I-NNLS","NNLM","cor")
    ## methods <- c("NNLM","cor")
    ##if(ncol(ngs$counts)>100) methods <- setdiff(methods,"CIBERSORT")  ## too slow...

    ## list of reference matrices
    refmat <- list()
    readSIG <- function(f) read.csv(file.path(lib.dir,f), row.names=1, check.names=FALSE)
    LM22 <- read.csv(file.path(lib.dir,"LM22.txt"),sep="\t",row.names=1)
    refmat[["Immune cell (LM22)"]] <- LM22
    refmat[["Immune cell (ImmProt)"]] <- readSIG("immprot-signature1000.csv")
    refmat[["Immune cell (DICE)"]] <- readSIG("DICE-signature1000.csv")
    refmat[["Immune cell (ImmunoStates)"]] <- readSIG("ImmunoStates_matrix.csv")
    refmat[["Tissue (HPA)"]]       <- readSIG("rna_tissue_matrix.csv")
    refmat[["Tissue (GTEx)"]]      <- readSIG("GTEx_rna_tissue_tpm.csv")
    refmat[["Cell line (HPA)"]]    <- readSIG("HPA_rna_celline.csv")
    refmat[["Cell line (CCLE)"]] <- readSIG("CCLE_rna_celline.csv")
    refmat[["Cancer type (CCLE)"]] <- readSIG("CCLE_rna_cancertype.csv")

    ## list of methods to compute
    ##methods = DECONV.METHODS
    methods = c("DCQ","DeconRNAseq","I-NNLS","NNLM","cor","CIBERSORT","EPIC")
    ## methods <- c("NNLM","cor")

    if(full==FALSE) {
        ## Fast methods, subset of references
        sel = c("Immune cell (LM22)","Immune cell (ImmunoStates)",
                "Immune cell (DICE)","Immune cell (ImmProt)",
                "Tissue (GTEx)","Cell line (HPA)","Cancer type (CCLE)")
        refmat <- refmat[intersect(sel,names(refmat))]
        methods <- c("DCQ","DeconRNAseq","I-NNLS","NNLM","cor")        
    }
    
    ##counts <- ngs$counts
    counts <- rna.counts
    rownames(counts) <- toupper(ngs$genes[rownames(counts),"gene_name"])
    res <- pgx.multipleDeconvolution(counts, refmat=refmat, method=methods)

    ngs$deconv <- res$results
    rownames(res$timings) <- paste0("[deconvolution]",rownames(res$timings))
    res$timings
    ngs$timings <- rbind(ngs$timings, res$timings)

    remove(refmat)
    remove(res)

    return(ngs)
}

## -------------- infer sample characteristics --------------------------------
compute.cellcycle.gender <- function(ngs, rna.counts=ngs$counts)
{
    pp <- rownames(rna.counts)
    is.mouse = (mean(grepl("[a-z]",gsub(".*:|.*\\]","",pp))) > 0.8)
    is.mouse
    if(!is.mouse) {
        if(1) {
            message("estimating cell cycle (using Seurat)...")
            ngs$samples$cell.cycle <- NULL
            ngs$samples$.cell.cycle <- NULL
            ##counts <- ngs$counts
            counts <- rna.counts
            rownames(counts) <- toupper(ngs$genes[rownames(counts),"gene_name"])
            res <- try(pgx.inferCellCyclePhase(counts) )  ## can give bins error
            if(class(res)!="try-error") {
                ngs$samples$.cell_cycle <- res
                table(ngs$samples$.cell_cycle)
            }
        }
        if(!(".gender" %in% colnames(ngs$samples) )) {
            message("estimating gender...")
            ngs$samples$.gender <- NULL
            X <- log2(1+rna.counts)
            gene_name <- ngs$genes[rownames(X),"gene_name"]
            ngs$samples$.gender <- pgx.inferGender( X, gene_name )
            table(ngs$samples$.gender)
        } else {
            message("gender already estimated. skipping...")
        }
        head(ngs$samples)
    }
    return(ngs)
}


compute.drugActivityEnrichment <- function(ngs, lib.dir ) {

    ## -------------- drug enrichment
    L1000.FILE = "l1000_es_n20a1698.csv.gz"
    L1000.FILE = "l1000_es_n20d1011.csv.gz"
    L1000.FILE = "l1000_es.csv.gz"
    message("[compute.drugActivityEnrichment] reading L1000 reference: ",L1000.FILE)
    ##X <- readRDS(file=file.path(lib.dir,L1000.FILE))
    X <- fread.csv(file=file.path(lib.dir,L1000.FILE))
    
    xdrugs <- gsub("_.*$","",colnames(X))
    ndrugs <- length(table(xdrugs))
    ndrugs
    message("number of profiles: ",ncol(X))
    message("number of drugs: ",ndrugs)
    dim(X)

    res.mono = NULL    
    NPRUNE=-1
    NPRUNE=250
    res.mono <- pgx.computeDrugEnrichment(
        ngs, X, xdrugs, methods=c("GSEA","cor"),
        nprune=NPRUNE, contrast=NULL )

    if(is.null(res.mono)) {
        cat("[compute.drugActivityEnrichment] WARNING:: pgx.computeDrugEnrichment failed!\n")
        return(ngs)
    }

    ## attach annotation
    annot0 <- read.csv(file.path(lib.dir,"L1000_repurposing_drugs.txt"),
                       sep="\t", comment.char="#")
    annot0$drug <- annot0$pert_iname
    rownames(annot0) <- annot0$pert_iname
    head(annot0)    
    dim(res.mono[["GSEA"]]$X)

    ##ngs$drugs <- NULL
    ngs$drugs[["activity/L1000"]]  <- res.mono[["GSEA"]]
    ngs$drugs[["activity/L1000"]][["annot"]] <- annot0[,c("drug","moa","target")]

    remove(X)
    remove(xdrugs)
    return(ngs)
}

##ref="CTRPv2";lib.dir="../lib";combo=FALSE
compute.drugSensitivityEnrichment <- function(ngs, lib.dir, ref.db=c("CTRPv2","GDSC") )
{
    ref <- ref.db[1]
    for(ref in ref.db) {
        ##X <- readRDS(file=file.path(lib.dir,"drugSX-GDSC-t25-g1000.rds"))
        ##X <- readRDS(file=file.path(lib.dir,"drugSX-CTRPv2-t25-g1000.rds"))
        X <- readRDS(file=file.path(lib.dir,paste0("drugSX-",ref,"-t25-g1000.rds")))
        xdrugs <- gsub("@.*$","",colnames(X))
        length(table(xdrugs))
        dim(X)
        
        res.mono = NULL
        
        NPRUNE=-1
        NPRUNE=250
        res.mono <- pgx.computeDrugEnrichment(
            ngs, X, xdrugs, methods=c("GSEA","cor"),
            nprune=NPRUNE, contrast=NULL )
        
        if(is.null(res.mono)) {
            cat("[compute.drugActivityEnrichment] WARNING:: pgx.computeDrugEnrichment failed!\n")
            return(ngs)
        }
        
        ## attach annotation
        ##annot0 <- read.csv(file.path(lib.dir,"drugSX-GDSC-drugs.csv"))
        ##annot0 <- read.csv(file.path(lib.dir,"drugSX-CTRPv2-drugs.csv"))
        annot0 <- read.csv(file.path(lib.dir,paste0("drugSX-",ref,"-drugs.csv")))
        head(annot0)
        rownames(annot0) <- annot0$drug
                
        s1 <- paste0("sensitivity/",ref)
        s2 <- paste0("sensitivity-combo/",ref)
        ngs$drugs[[s1]] <- res.mono[["GSEA"]]
        ngs$drugs[[s1]][["annot"]] <- annot0[,c("moa","target")]

    } ## end of for rr
    
    names(ngs$drugs)
    
    remove(X)
    remove(xdrugs)
    return(ngs)
}

##ref="CTRPv2";lib.dir="../lib"
compute.genePerturbationEnrichment <- function(ngs, lib.dir)
{
    L1000.FILE = "l1000_gpert_n10g1766.csv.gz"
    L1000.FILE = "l1000_gpert_n8g5812.csv.gz"
    L1000.FILE = "l1000_gpert.csv.gz"
    message("[compute.drugActivityEnrichment] reading L1000 reference: ",L1000.FILE)
    ##X <- readRDS(file=file.path(lib.dir,L1000.FILE))
    X <- fread.csv(file=file.path(lib.dir,L1000.FILE))

    ## -------------- drug enrichment    
    xdrugs <- gsub("_.*$","",colnames(X))
    ndrugs <- length(table(xdrugs))
    ndrugs
    message("number of profiles: ",ncol(X))
    message("number of gene perturbations: ",ndrugs)
    dim(X)

    NPRUNE=-1
    NPRUNE=250
    res <- pgx.computeDrugEnrichment(
        ngs, X, xdrugs, methods=c("GSEA","cor"),
        nmin=3, nprune=NPRUNE, contrast=NULL )

    if(is.null(res)) {
        cat("[compute.genePerturbationEnrichment] WARNING:: computing failed!\n")
        return(ngs)
    }

    ## attach annotation
    dd <- rownames(res[["GSEA"]]$X)
    ##d1 <- sub(".*-","",dd)
    d1 <- dd
    d2 <- sub("-.*","",dd)
    annot0 <- data.frame(drug=dd, moa=d1, target=d2)
    rownames(annot0) <- dd
    head(annot0)
        
    dim(res[["GSEA"]]$X)

    ##ngs$drugs <- NULL
    ngs$drugs[["gene/L1000"]]  <- res[["GSEA"]]
    ngs$drugs[["gene/L1000"]][["annot"]] <- annot0[,c("drug","moa","target")]

    remove(X)
    remove(xdrugs)
    return(ngs)
}

## ------------------ Omics graphs --------------------------------
compute.omicsGraphs <- function(ngs) {
    ## gr1$layout <- gr1$layout[V(gr1)$name,]  ## uncomment to keep entire layout
    ngs$omicsnet <- pgx.createOmicsGraph(ngs)
    ngs$pathscores <- pgx.computePathscores(ngs$omicsnet, strict.pos=FALSE)

    ## compute reduced graph
    ngs$omicsnet.reduced <- pgx.reduceOmicsGraph(ngs)
    ngs$pathscores.reduced <- pgx.computePathscores(ngs$omicsnet.reduced, strict.pos=FALSE)
    ##save(ngs, file=rda.file)
    return(ngs)
}

