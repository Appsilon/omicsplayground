##
## This file is part of the Omics Playground project.
## Copyright (c) 2018-2020 BigOmics Analytics Sagl. All rights reserved.
##

require(scran)
require(igraph)

pgx.computePathscores <- function(graph, strict.pos=TRUE)
{
    require(igraph)
    if(0) {
        graph <- ngs$omicsnet
        graph <- ngs$omicsnet.reduced
    }
    
    ## add source/sink
    graph <- pgx._addSourceSink(graph)

    ## calculate weights for this particular contrast
    F <- graph$foldchange
    P <- matrix(NA, nrow=length(V(graph)), ncol=ncol(F))
    rownames(P) <- V(graph)$name
    colnames(P) <- colnames(F)
    i=1
    for(i in 1:ncol(F)) {
        
        fc <- graph$foldchange[,i]
        ee <- get.edges(graph, E(graph))
        dim(ee)
        if(strict.pos) {
            f1 <- pmax(fc[ee[,1]],0)  ## strictly positive
            f2 <- pmax(fc[ee[,2]],0)
            node.values <- sqrt(abs(f1 * f2)) ## strictly positive
            edge.rho <- pmax(E(graph)$weight,0)
        } else {
            f1 <- fc[ee[,1]]  ## strictly positive
            f2 <- fc[ee[,2]]
            node.values <- sqrt(abs(f1*f2)) ## strictly positive
            edge.rho <- abs(E(graph)$weight)
        }
        score <- node.values * edge.rho  ## always positive
        weights0 <- -log(pmax(score/max(score),1e-8))
        length(weights0)
        summary(weights0)
        
        ##----------------------------------------------------------
        ## Compute pathscore (solve all distances, 3-point SP)
        ##----------------------------------------------------------
        dist.source <- distances(graph, v="SOURCE", weights = weights0)
        dist.sink   <- distances(graph, v="SINK", weights = weights0)
        w1 <- rep(1, length(E(graph)))
        ##len.source <- distances(graph, v="SOURCE", weights = w1)
        ##len.sink   <- distances(graph, v="SINK", weights = w1)
        path.score <- exp(-(dist.source + dist.sink))
        names(path.score) <- V(graph)$name
        P[,i] <- path.score
    }
    dim(P)

    if(0) {
        P1 <- P[grep("\\{gene\\}",rownames(P)),]
        jj <- order(-rowMeans(P1**2))
        head(P1[jj,])
        head(graph$members[rownames(P1)[jj]])
        
        P2 <- P[grep("\\{geneset\\}",rownames(P)),]
        jj <- order(-rowMeans(P2**2))
        head(P2[jj,],10)
        head(graph$members[rownames(P2)[jj]])
    }

    return(P)
}

pgx.computeShortestPath <- function(graph, contrast, niter=1, r=0.01,
                                    output="vpath")
{
    require(igraph)
    if(0) {
        graph <- ngs$omicsnet
        graph <- ngs$omicsnet.reduced
        tf.genes <- FAMILIES[["Transcription factors (ChEA)"]]
        graph <- pgx.createVipGeneLayer(graph, tf.genes, z=0, reconnect=20) 
        niter=10;r=0.10;contrast=3;output="both"
    }
    
    ## add source/sink
    graph <- pgx._addSourceSink(graph)

    ## calculate weights
    fc <- graph$foldchange[,contrast]
    ee <- get.edges(graph, E(graph))
    dim(ee)
    f1 <- pmax(fc[ee[,1]],0)
    f2 <- pmax(fc[ee[,2]],0)
    node.values <- sqrt(f1 * f2) ## strictly positive
    edge.rho <- pmax(E(graph)$weight,0)
    score <- node.values * edge.rho
    weights0 <- -log(pmax(score/max(score),1e-8))
    length(weights0)
    summary(weights0)
    
    ##----------------------------------------------------------
    ## solve single SP (SOURCE to SINK)
    ##----------------------------------------------------------
    vpath <- list()
    epath <- list()
    if(niter>0) {
        for(i in 1:niter) {
            sd0 <- r*sd(weights0)
            weights1 <- 0.0 + pmax(weights0 + sd0*rnorm(length(weights0)),0)
            ##weights1 <- weights0
            system.time(
                sp.out <- shortest_paths(graph, from="SOURCE", to = "SINK", mode = "all",
                                         weights = weights1, output = output)
            )
            nv <- length(sp.out$vpath[[1]])
            ne <- length(sp.out$epath[[1]])
            vpath[[i]] <- sp.out$vpath[[1]]$name[2:(nv-1)]
            epath[[i]] <- sp.out$epath[[1]][2:(ne-1)]
        }
    }    
    ##sapply(sp, function(x) x$vpath[[1]]$name)
    vfreq <- sort(table(unlist(vpath)),decreasing=TRUE)

    ##efreq <- sort(table(unlist(epath)),decreasing=TRUE)
    if(0) {
        head(vfreq)
        vtop <- names(vfreq)
        head(graph$members[vtop])
        fc[vtop]
        graph$members[ends(graph, epath[[2]])]

    }
    
    res <- list(vpath=vpath, epath=epath, vfreq=vfreq)
    return(res)
}

pgx._addSourceSink <- function(gr) {
    min.level <- min(gr$layout[V(gr)$name,3])
    max.level <- max(gr$layout[V(gr)$name,3])
    min.level
    max.level
    
    gr <- add_vertices(gr, 2, name=c("SOURCE","SINK"))
    ss.layout <- rbind( "SOURCE"=c(0,0,-999),"SINK"=c(0,0,999))
    gr$layout <- rbind(gr$layout, ss.layout)
    nfc <- ncol(gr$foldchange)
    ss.foldchange <- rbind( "SOURCE"=rep(1,nfc),"SINK"=rep(1,nfc))
    gr$foldchange <- rbind( gr$foldchange, ss.foldchange)
    gr$scaled.data <- rbind( gr$scaled.data,
                            "SOURCE"=rep(NA,ncol(gr$scaled.data)),
                            "SINK"=rep(NA,ncol(gr$scaled.data)) )
    
    level <- gr$layout[V(gr)$name,3]
    i1 <- which(level==min.level)
    i2 <- which(level==max.level)
    ee1 <- data.frame( from="SOURCE", to=V(gr)$name[i1])
    ee2 <- data.frame( from=V(gr)$name[i2], to="SINK")
    ee <- rbind(ee1, ee2)
    gr <- add_edges(gr, as.vector(t(ee)), weight=1)
    return(gr)
}


pgx.createOmicsGraph <- function(ngs, do.intersect=TRUE )
{
    ##======================================================================
    ## Create a graph object by merging nodes into
    ## clusters of genes/genesets.
    ##
    ##
    ## make bipartite igraph object
    ##======================================================================
    require(scran)
    
    ##----------------------------------------------------------------------
    ## Read in gene/geneset graph structure
    ##----------------------------------------------------------------------
    ##gr <- readRDS(file.path(FILES,"pgx-graph-geneXgset-XL.rds"))
    gr <- readRDS(file.path(FILES,"pgx-graph-geneXgset-XL-snn20.rds"))
    table(V(gr)$level)

    ##load(file = file.path(FILES,"gset-sparseG-XL.rda"), verbose=1)
    ##G <- as_adjacency_matrix(gr)
    ##dim(G)

    ##----------------------------------------------------------------------
    ## Create large data matrix (includes all levels)
    ##----------------------------------------------------------------------
    xx1 <- ngs$X
    ## REALLY???
    ##if("hgnc_symbol" %in% colnames(ngs$genes)) rownames(xx1) <- ngs$genes$hgnc_symbol
    ##rownames(xx1) <- paste0("{gene}",alias2hugo(rownames(ngs$X)))
    gene <- toupper(ngs$genes[rownames(xx1),"gene_name"])
    rownames(xx1) <- paste0("{gene}",gene)
    ##rownames(xx1) <- paste0("{gene}",ngs$genes$gene_name)
    xx2 <- ngs$gsetX
    rownames(xx2) <- paste0("{geneset}",rownames(ngs$gsetX))
    xx <- rbind(xx1, xx2)
    xx <- t(scale(t(xx)))  ## scale??, then use innerproduct/cosine distance
    dim(xx)
    remove(xx1,xx2)

    ##----------------------------------------------------------------------
    ## Prepare fold-change matrix 
    ##----------------------------------------------------------------------
    names(ngs$gx.meta$meta)
    F <- sapply( ngs$gx.meta$meta, function(x) unclass(x$fc)[,"trend.limma"])
    F <- F / max(abs(F),na.rm=TRUE)
    S <- sapply( ngs$gset.meta$meta, function(x) unclass(x$fc)[,"gsva"])
    S <- S / max(abs(S),na.rm=TRUE)
    dim(S)
    rownames(S) <- paste0("{geneset}",rownames(S))
    ##rownames(F) <- paste0("{gene}",rownames(F))
    fgene <- toupper(ngs$genes[rownames(F),"gene_name"])
    rownames(F) <- paste0("{gene}",fgene)

    kk <- intersect(colnames(F),colnames(S))
    fc <- rbind(F[,kk,drop=FALSE],S[,kk,drop=FALSE])
    dim(F)
    dim(S)
    remove(F);remove(S)

    ##table(V(gr)$name %in% rownames(xx))
    table(rownames(xx) %in% V(gr)$name)
    table(rownames(fc) %in% V(gr)$name)
    head(setdiff(rownames(xx), V(gr)$name))
    head(setdiff(rownames(fc), V(gr)$name))
    tail(V(gr)$name)
    tail(rownames(fc))

    sel <- intersect(rownames(xx), rownames(fc))
    sel <- sort(intersect(sel,V(gr)$name))
    gr1 <- induced_subgraph(gr, sel)
    gr1
    xx <- xx[V(gr1)$name,,drop=FALSE]
    fc <- fc[V(gr1)$name,,drop=FALSE]

    ## save the matched foldchange matrix
    gr1$foldchange  <- fc
    gr1$scaled.data <- xx
    
    ##----------------------------------------------------------------------
    ## should we recreate the SNNgraph in the intralayers????
    ##----------------------------------------------------------------------
    if(1) {
        table(V(gr1)$level)
        ## this connect all points with at least 3 neighbours
        sel1 <- which( V(gr1)$level=="gene")
        pos1 <- gr$layout[V(gr1)[sel1]$name,]
        head(pos1)
        r1 <- buildSNNGraph(t(pos1), k=3)
        V(r1)$name <- V(gr1)[sel1]$name

        sel2 <- which( V(gr1)$level=="geneset")
        pos2 <- gr$layout[V(gr1)[sel2]$name,]
        head(pos2)
        r2 <- buildSNNGraph(t(pos2), k=3)
        V(r2)$name <- V(gr1)[sel2]$name
        new.gr <- graph.union(gr1, r1)
        new.gr <- graph.union(new.gr, r2)
        gr1 <- new.gr
    }
    
    ## get rid of all weight attributes
    attr <- edge_attr_names(gr1)
    attr <- attr[grep("weight|rho",attr)]
    attr
    if(length(attr)) {
        for(i in 1:length(attr)) gr1 <- remove.edge.attribute(gr1,attr[i])
    }

    ##----------------------------------------------------------------------
    ##  set correlation on edges
    ##----------------------------------------------------------------------
    ee <- get.edges(gr1, E(gr1) )
    dim(ee)
    ee.rho <- rep(NA, nrow(ee))
    bs <- 100000
    nblock <- ceiling(nrow(ee)/bs)
    nblock
    k=2
    for(k in 1:nblock) {
        i0 <- (k-1)*bs + 1
        i1 <- min(i0+bs-1, nrow(ee))
        ii <- i0:i1
        ## fast method to compute rowwise-correlation (xx should be row-scaled)
        ee.rho[ii] <- rowMeans( xx[ee[ii,1],] * xx[ee[ii,2],] )  
    }
    E(gr1)$weight <- ee.rho  ## replace weight with correlation
    
    ##----------------------------------------------------------------------
    ## cluster graph
    ##----------------------------------------------------------------------
    idx <- cluster_louvain(gr1, weights=abs(E(gr1)$weight) )$membership
    V(gr1)$cluster <- idx

    gr1
    return(gr1)
}


pgx.reduceOmicsGraph <- function(ngs)
{
    ##======================================================================
    ## Create a 'reduced' representation graph by merging nodes into
    ## clusters of genes/genesets.
    ##
    ##
    ## make bipartite igraph object
    ##======================================================================
    require(scran)
    require(igraph)
    ##require(threejs)

    ## get full omics graph
    gr <- ngs$omicsnet
    if(is.null(gr)) {
        stop("FATAL ERROR:: no omicsnet in ngs object. first run pgx.createOmicsGraph().")
    }

    summary(E(gr)$weight)

    ##------------------------------------------------------------
    ## conform features
    ##------------------------------------------------------------
    v1 <- which(V(gr)$level=="gene")
    v2 <- which(V(gr)$level=="geneset")
    g1 <- induced_subgraph(gr, v1)
    g2 <- induced_subgraph(gr, v2)
    g1 <- delete_edge_attr(g1, "weight")
    g2 <- delete_edge_attr(g2, "weight")
    h1 <- hclust_graph(g1)
    h2 <- hclust_graph(g2)
    apply(h1,2,function(x)length(table(x)))
    apply(h2,2,function(x)length(table(x)))
    hc1 <- paste0("{gene}cluster",h1[,ncol(h1)])
    hc2 <- paste0("{geneset}cluster",h2[,ncol(h2)])
    names(hc1) <- V(g1)$name
    names(hc2) <- V(g2)$name

    ##------------------------------------------------------------
    ## create reduction transform matrix
    ##------------------------------------------------------------
    idx0 <- c(h1[,1],h2[,1])[V(gr)$name]
    idx  <- c(hc1,hc2)[V(gr)$name]
    R <- t(model.matrix( ~ 0 + idx))
    R <- R / rowSums(R)
    dim(R)
    colnames(R) <- V(gr)$name
    rownames(R) <- sub("^idx","",rownames(R))

    ## reduce all variable: weights (correlation)
    rA <- (R %*% gr[,]) %*% t(R)   ## weights
    rA <- (rA + t(rA)) / 2
    dim(rA)

    ## reduced data matrix
    rX <- R %*% gr$scaled.data

    ## reduced fold-change
    rF <- R %*% gr$foldchange

    ##------------------------------------------------------------
    ## keep group indices
    ##------------------------------------------------------------
    grp.members <- tapply( names(idx), idx, list)
    grp.members0 <- grp.members
    grp.members <- lapply( grp.members, function(s) gsub("^\\{.*\\}","",s))
    grp.label   <- lapply( grp.members, function(s) paste(s,collapse="\n"))

    ##------------------------------------------------------------
    ## create reduced combined graph
    ##------------------------------------------------------------
    gr1 <- graph_from_adjacency_matrix( as.matrix(rA), mode="undirected",
                                       weighted=TRUE, diag=FALSE)

    ##rpos <- (R %*% gr$layout)
    ee <- get.edges(gr1, E(gr1))
    summary(E(gr1)$weight)
    table( abs(E(gr1)$weight) > 0.01)
    table( abs(E(gr1)$weight) > 0.05)
    lev <- V(gr1)$level
    ee.type <- c("inter","intra")[ 1 + 1*(lev[ee[,1]]==(lev[ee[,2]]))]
    gr1 <- delete_edges(gr1, which(  abs(E(gr1)$weight) < 0.01 & ee.type == "inter"))
    ##gr1 <- subgraph.edges(gr1, which(abs(E(gr1)$weight) > 0.05), delete.vertices=FALSE)

    ##------------------------------------------------------------
    ## compute new layout positions???
    ##------------------------------------------------------------
    rpos <- lapply( grp.members0, function(m) colMeans(gr$layout[m,,drop=FALSE]))
    rpos <- do.call( rbind, rpos)
    gr1$layout <- scale(rpos)
    ##gr1 <- buildSNNGraph(t(rpos), k=20)

    if(1) {
        ## should we recreate the SNNgraph in the intralayers????
        ## this connect all points with at least 3 neighbours
        vtype <- gsub("\\}.*|^\\{","",V(gr1)$name)
        sel1 <- which( vtype=="gene")
        pos1 <- gr1$layout[V(gr1)[sel1]$name,]
        head(pos1)
        r1 <- buildSNNGraph(t(pos1), k=3)
        V(r1)$name <- rownames(pos1)

        sel2 <- which( vtype=="geneset")
        pos2 <- gr1$layout[V(gr1)[sel2]$name,]
        head(pos2)
        r2 <- buildSNNGraph(t(pos2), k=3)
        V(r2)$name <- rownames(pos2)
        new.gr <- graph.union(r1, r2)
        new.gr <- remove.edge.attribute(new.gr,"weight_1")
        new.gr <- remove.edge.attribute(new.gr,"weight_2")
        new.gr <- graph.union(gr1, new.gr)
        edge_attr_names(new.gr)
        jj <- which(is.na(E(new.gr)$weight))
        E(new.gr)$weight[jj] <- 0  ## actually we should recompute this....
        gr1 <- new.gr
    }

    ##------------------------------------------------------------
    ## add some graph data
    ##------------------------------------------------------------
    ##V(gr1)$members <- grp.idx
    V(gr1)$label <- grp.label
    V(gr1)$cluster <- tapply(idx0, idx, median)  ## level 1 cluster index
    V(gr1)$level <- gsub("\\}.*|^\\{","",V(gr1)$name)
    table(V(gr1)$level)

    gr1$foldchange <- rF
    gr1$members <- grp.members
    gr1$scaled.data <- rX
    
    ##klr <- rep(rainbow(24),99)[V(gr1)$cluster]
    ##graphjs(gr1, vertex.size=0.3, vertex.color=klr)

    return(gr1)
}

pgx.createVipGeneLayer <- function(gr, genes, z=0, reconnect=40) {
    ##
    ## Create seperate VIP layer from given genes and remove peeping
    ## links.
    ##
    if(0) {
        genes <- FAMILIES[[11]]
        reconnect=100;z=0
    }

    vname <- sub(".*\\}","",V(gr)$name)
    vip <- V(gr)[which(vname %in% genes)]
    V(gr)[vip]$level <- "VIP"
    gr$layout <- gr$layout[V(gr)$name,]
    gr$layout[V(gr)[vip]$name,3] <- z  ## new layer position
    table(gr$layout[,3])

    ##----------------------------------------------------------------------
    ## remove "shortcut" links
    ##----------------------------------------------------------------------
    ee <- get.edges(gr, E(gr))
    lv1 <- V(gr)$level[ee[,1]]
    lv2 <- V(gr)$level[ee[,2]]
    ee.type <- c("intralayer","interlayer")[ 1 + 1*(lv1!=lv2)]
    table(ee.type)
    link.dist <- abs(gr$layout[ee[,1],3] - gr$layout[ee[,2],3])
    summary(link.dist)
    ee.delete <- (ee.type=="interlayer" &  link.dist > 1.5 )
    table(ee.delete)
    gr1 <- delete_edges(gr, which(ee.delete))

    ##----------------------------------------------------------------------
    ## Reconnect VIP nodes with more connectsion in next layer
    ##----------------------------------------------------------------------
    if(reconnect>0) {
        cat("createVipGeneLayer:: reconnecting VIP nodes to next layer\n")
        level <- gr1$layout[,3]
        vip.level <- gr1$layout[vip,3]
        next.level <- min(sort(setdiff(unique(gr1$layout[,3]),vip.level)))
        next.level
        next.nodes <- V(gr1)$name[which(level==next.level)]
        rho1 <- cor( t(gr1$scaled.data[vip,]), t(gr1$scaled.data[next.nodes,]))
        dim(rho1)
        connections <- c()
        i=1
        for(i in 1:nrow(rho1)) {
            nnb <- head(order(-rho1[i,]),reconnect)
            cnc <- data.frame( rownames(rho1)[i], colnames(rho1)[nnb], rho1[i,nnb])
            connections <- rbind(connections, cnc)
        }
        vname1 <- V(gr1)$name
        ee1 <- cbind( match(connections[,1],vname1), match(connections[,2],vname1) )
        jj <- which(rowSums(is.na(ee1))==0)
        gr1 <- add_edges(gr1, edges=as.vector(t(ee1[jj,])), weight=connections[jj,3])
    }
    
    ##----------------------------------------------------------------------
    ## Reconnect VIP links with more neighbours (looks nicer)
    ##----------------------------------------------------------------------
    if(1) {
        cat("createVipGeneLayer:: reconnecting VIP nodes within VIP layer\n")
        pos1 <- gr1$layout[vip,1:2]
        gr2  <- buildSNNGraph(t(pos1), k=5)
        ##V(gr2)$name <- sub(".*\\}","",rownames(pos1))
        V(gr2)$name <- rownames(pos1)
        gr2$layout <- pos1
        vv  <- get.edgelist(gr2)
        rho <- rowMeans(gr1$scaled.data[vv[,1],] * gr1$scaled.data[vv[,2],]) ## rho
        vname1 <- V(gr1)$name
        ee1 <- cbind( match(vv[,1],vname1), match(vv[,2],vname1) )
        jj <- which(rowSums(is.na(ee1))==0)
        gr1 <- add_edges(gr1, edges=as.vector(t(ee1[jj,])), weight=rho[jj])
    }

    return(gr1)
}


##cex=4;gene="CDK4";fx=main=NULL;gr=ngs$omicsnet
pgx.plotDualProjection <- function(gr, gene=NULL, geneset=NULL,
                                   cex=1, fx=NULL, main=NULL, plot=TRUE )
{
    if( !is.null(gene) && !is.null(geneset) ) {
        stop("either gene or geneset must be non-null!")
    }
    require(gplots)

    dim(gr$layout)
    vtype <- gsub("\\}.*|^\\{","",rownames(gr$layout))
    tsne_genes <- gr$layout[which(vtype=="gene"),]
    tsne_gsets <- gr$layout[which(vtype=="geneset"),]
    dim(tsne_genes)
    dim(tsne_gsets)

    uscale <- function(x) (x-min(x))/(max(x)-min(x))-0.5
    pos1 <- apply(tsne_gsets[,1:2],2,uscale)
    pos2 <- apply(tsne_genes[,1:2],2,uscale)
    pos1 <- t( t(pos1) + c(+0.6,0))
    pos2 <- t( t(pos2) + c(-0.6,0))

    ##geneset="C2:KEGG_T_CELL_RECEPTOR_SIGNALING_PATHWAY";gene=NULL
    ##gene="KCNN4";geneset=NULL
    tt="";to=from=NULL
    if(!is.null(geneset)) {
        gs = paste0("{geneset}",geneset)
        if(0 && "members" %in% graph_attr_names(gr)) {
            gs <- names(which(sapply(gr$members, function(x) any(x==geneset))))
        }
        ##gg = colnames(G)[which(G[grep(gs,rownames(G)),]!=0)]
        if(gs %in% V(gr)$name) {
            nb <- V(gr)[neighbors(gr, gs)]$name
            gg = intersect(nb, rownames(pos2))
            from = pos1[gs,]
            to   = pos2[gg,,drop=FALSE]
        }
        tt = geneset
    }
    if(!is.null(gene)) {
        gg = paste0("{gene}",gene)
        ##gg = colnames(G)[which(G[grep(gs,rownames(G)),]!=0)]
        if(0 && "members" %in% graph_attr_names(gr)) {
            gg <- names(which(sapply(gr$members, function(x) any(x==gene))))
        }
        if(gg %in% V(gr)$name) {
            nb <- V(gr)[neighbors(gr, gg)]$name
            gs = intersect(nb, rownames(pos1))
            from = pos2[gg,]
            to = pos1[gs,,drop=FALSE]
        } else {
            cat("WARNING::",gg," not in omicsgraph\n")
        }
        tt = gene
    }
    dim(to)

    if(plot==TRUE) {
        cex1 <- 1 + 1*(rownames(pos1) %in% V(gr)$name)
        klr1 <- c("grey70","grey10")[cex1]
        cex2 <- 1 + 1*(rownames(pos2) %in% V(gr)$name)
        klr2 <- c("grey70","grey10")[cex2]
        if(!is.null(fx)) {
            fx1 <- fx[match(rownames(pos1),names(fx))]
            fx2 <- fx[match(rownames(pos2),names(fx))]
            ##fx1[is.na(fx1)] <- 0
            ##fx2[is.na(fx2)] <- 0
            fx1 <- fx1 / max(abs(fx1),na.rm=TRUE)
            fx2 <- fx2 / max(abs(fx2),na.rm=TRUE)
            klr1 = bluered(32)[16 + round(15*fx1)]
            klr2 = bluered(32)[16 + round(15*fx2)]
            ix1 <- cut(fx1, breaks=c(-99,-0.1,0.1,99))
            ix2 <- cut(fx2, breaks=c(-99,-0.1,0.1,99))
            klr1 = c("blue","gray40","red")[as.integer(ix1)]
            klr2 = c("blue","gray40","red")[ix2]
            klr1[which(is.na(klr1))] <- "grey80"
            klr2[which(is.na(klr2))] <- "grey80"
        }

        cex=0.02
        if(nrow(pos1) < 1000) cex=0.4
        pch="."
        pch=20
        j1 <- 1:length(klr1)
        if(length(klr1)>5000) {
            j1 <- c(sample(grep("grey",klr1),5000), which(klr1!="grey"))
        }
        plot( pos1[j1,], pch=pch, xlim=c(-1.1, 1.1), ylim=c(-0.5, 0.5),
             xaxt="n", yaxt="n", xlab="", ylab="", bty="n",
             col=klr1[j1], cex=cex*cex1[j1] )

        j2 <- 1:nrow(pos2)
        if(length(klr2)>5000) {
            j2 <- c(sample(grep("grey",klr2),5000), which(klr2!="grey") )
        }
        points( pos2[j2,], pch=pch, cex=cex*cex2[j2], col=klr2[j2], main="genes")

        legend("bottomleft", "GENES", bty="n", col="grey60")
        legend("bottomright", "GENE SETS", bty="n", col="grey60")
        if(!is.null(from)) {
            points( from[1], from[2], pch=20, cex=1, col="green3")
            points( to[,1], to[,2], pch=20, cex=0.4, col="green3")
            arrows( from[1], from[2], to[,1], to[,2], length=0.05,
                   lwd=0.5, col = paste0(col2hex("green3"),"33"))
            ##text( from[1], from[2], tt, col="blue", pos=3, font=2, cex=0.8, offset=0.2)
        }
        if(!is.null(main)) tt <- main
        mtext( tt, line=0.5, at=0, font=2, cex=1.1)
    }
    invisible(rownames(to))
}


pgx.plotForwardProjection <- function(gr, gene, cex=1, fx=NULL,
                                      features=NULL, main=NULL, plot=TRUE )
{
    require(gplots)
    if(0) {
        cex=4;gene="CDK4";fx=main=NULL;gr=ngs$omicsnet
    }

    if(!is.null(features)) {
        gr <- pgx.createVipGeneLayer(gr, genes)
    }

    dim(gr$layout)
    vtype <- gsub("\\}.*|^\\{","",rownames(gr$layout))
    tsne_genes <- gr$layout[which(vtype=="gene"),]
    tsne_gsets <- gr$layout[which(vtype=="geneset"),]
    dim(tsne_genes)
    dim(tsne_gsets)

    uscale <- function(x) (x-min(x))/(max(x)-min(x))-0.5
    pos1 <- apply(tsne_gsets[,1:2],2,uscale)
    pos2 <- apply(tsne_genes[,1:2],2,uscale)
    pos1 <- t( t(pos1) + c(+0.6,0))
    pos2 <- t( t(pos2) + c(-0.6,0))





    ## ---------------- get all edges/paths ---------------
    ##geneset="C2:KEGG_T_CELL_RECEPTOR_SIGNALING_PATHWAY";gene=NULL
    ##gene="KCNN4";geneset=NULL
    tt="";to=from=NULL
    if(!is.null(geneset)) {
        gs = paste0("{geneset}",geneset)
        if(0 && "members" %in% graph_attr_names(gr)) {
            gs <- names(which(sapply(gr$members, function(x) any(x==geneset))))
        }
        ##gg = colnames(G)[which(G[grep(gs,rownames(G)),]!=0)]
        if(gs %in% V(gr)$name) {
            nb <- V(gr)[neighbors(gr, gs)]$name
            gg = intersect(nb, rownames(pos2))
            from = pos1[gs,]
            to   = pos2[gg,,drop=FALSE]
        }
        tt = geneset
    }

    if(!is.null(gene)) {
        gg = paste0("{gene}",gene)
        ##gg = colnames(G)[which(G[grep(gs,rownames(G)),]!=0)]
        if(0 && "members" %in% graph_attr_names(gr)) {
            gg <- names(which(sapply(gr$members, function(x) any(x==gene))))
        }
        if(gg %in% V(gr)$name) {
            nb <- V(gr)[neighbors(gr, gg)]$name
            gs = intersect(nb, rownames(pos1))
            from = pos2[gg,]
            to = pos1[gs,,drop=FALSE]
        } else {
            cat("WARNING::",gg," not in omicsgraph\n")
        }
        tt = gene
    }
    dim(to)


    if(plot==TRUE) {
        cex1 <- 1 + 1*(rownames(pos1) %in% V(gr)$name)
        klr1 <- c("grey70","grey10")[cex1]
        cex2 <- 1 + 1*(rownames(pos2) %in% V(gr)$name)
        klr2 <- c("grey70","grey10")[cex2]
        if(!is.null(fx)) {
            fx1 <- fx[match(rownames(pos1),names(fx))]
            fx2 <- fx[match(rownames(pos2),names(fx))]
            ##fx1[is.na(fx1)] <- 0
            ##fx2[is.na(fx2)] <- 0
            fx1 <- fx1 / max(abs(fx1),na.rm=TRUE)
            fx2 <- fx2 / max(abs(fx2),na.rm=TRUE)
            klr1 = bluered(32)[16 + round(15*fx1)]
            klr2 = bluered(32)[16 + round(15*fx2)]
            ix1 <- cut(fx1, breaks=c(-99,-0.1,0.1,99))
            ix2 <- cut(fx2, breaks=c(-99,-0.1,0.1,99))
            klr1 = c("blue","gray40","red")[as.integer(ix1)]
            klr2 = c("blue","gray40","red")[ix2]
            klr1[which(is.na(klr1))] <- "grey80"
            klr2[which(is.na(klr2))] <- "grey80"
        }

        cex=0.02
        if(nrow(pos1) < 1000) cex=0.4
        pch="."
        pch=20
        j1 <- 1:length(klr1)
        if(length(klr1)>5000) {
            j1 <- c(sample(grep("grey",klr1),5000), which(klr1!="grey"))
        }
        plot( pos1[j1,], pch=pch, xlim=c(-1.1, 1.1), ylim=c(-0.5, 0.5),
             xaxt="n", yaxt="n", xlab="", ylab="", bty="n",
             col=klr1[j1], cex=cex*cex1[j1] )

        j2 <- 1:nrow(pos2)
        if(length(klr2)>5000) {
            j2 <- c(sample(grep("grey",klr2),5000), which(klr2!="grey") )
        }
        points( pos2[j2,], pch=pch, cex=cex*cex2[j2], col=klr2[j2], main="genes")

        legend("bottomleft", "GENES", bty="n", col="grey60")
        legend("bottomright", "GENE SETS", bty="n", col="grey60")
        if(!is.null(from)) {
            points( from[1], from[2], pch=20, cex=1, col="green3")
            points( to[,1], to[,2], pch=20, cex=0.4, col="green3")
            arrows( from[1], from[2], to[,1], to[,2], length=0.05,
                   lwd=0.5, col = paste0(col2hex("green3"),"33"))
            ##text( from[1], from[2], tt, col="blue", pos=3, font=2, cex=0.8, offset=0.2)
        }
        if(!is.null(main)) tt <- main
        mtext( tt, line=0.5, at=0, font=2, cex=1.1)
    }
    invisible(rownames(to))
}

##===================================================================================
##================================ GO graph functions ===============================
##===================================================================================
##fdr=0.05
pgx.computeCoreGOgraph <- function(ngs, fdr=0.05)
{

    ## test if there are GO terms
    mx = ngs$gset.meta$meta[[1]]
    jj = grep("^GO",rownames(mx))
    has.go <- (length(jj)>10)
    has.go
    if(!has.go) {
        cat("[pgx.computeCoreGOgraph] WARNING:: not enough GO terms in enrichment.\n")
        return(NULL)
    }

    ##comparison=comparisons[1];methods=c("fisher","gsva","camera");fdr=0.05
    comparisons = names(ngs$gset.meta$meta)
    comparisons
    subgraphs <- list()
    i=1
    for(i in 1:length(comparisons)) {
        subgraphs[[i]] = pgx.getSigGO(
            ngs, comparison=comparisons[i],
            methods = NULL,  ## should be actual selected methods!!
            fdr=fdr, nterms=200, ntop=20)
    }
    length(subgraphs)

    sub2 = igraph::graph.union(subgraphs, byname=TRUE)
    A = data.frame(vertex.attributes(sub2))
    rownames(A) = A$name
    colnames(A)

    go_graph <- getGOgraph()
    go_graph <- induced.subgraph( go_graph, V(sub2)$name )
    A = A[V(go_graph)$name,]
    Q = S = V = c()
    j1 = grep("^score",colnames(A))
    j2 = grep("^foldchange",colnames(A))
    j3 = grep("^qvalue",colnames(A))
    for(i in 1:length(comparisons)) {
        S = cbind(S, as.numeric(A[,j1[i]]))
        V = cbind(V, as.numeric(A[,j2[i]]))
        Q = cbind(Q, as.numeric(A[,j3[i]]))
    }
    rownames(Q) = rownames(V) = rownames(S) = rownames(A)
    colnames(Q) = colnames(V) = colnames(S) = comparisons

    ## can we match the GO terms with our gsetX values??
    go.sets <- grep("^GO.*\\(GO_",rownames(ngs$gsetX),value=TRUE)
    go.id <- gsub("GO_","GO:",gsub(".*\\(|\\)","",go.sets))
    matched.gset <- go.sets[ match( V(go_graph)$name, go.id) ]
    names(matched.gset) <- V(go_graph)$name

    ## compute FR layout
    layoutFR = layout_with_fr(go_graph)
    layoutFR[,1] = 1.33*layoutFR[,1]
    rownames(layoutFR) = V(go_graph)$name
    go_graph$layout = layoutFR
    V(go_graph)$label = V(go_graph)$Term
    go_graph
    res = list( graph=go_graph, pathscore=S, foldchange=V,
               qvalue=Q, match=matched.gset)
    return(res)
}


getGOgraph <- function() {
    ##install.packages(GOSim)
    ##require(GOSim)
    require(GO.db)
    require(igraph)
    terms <- toTable(GOTERM)[,2:5]
    terms <- terms[ !duplicated(terms[,1]), ]
    rownames(terms) = terms[,1]

    ##terms <- terms[ terms[,1] %in% vv, ]
    BP <- toTable(GOBPPARENTS)
    MF <- toTable(GOMFPARENTS)
    CC <- toTable(GOCCPARENTS)
    bp.terms = unique(c(BP[,1],BP[,2]))
    all.parents = rbind(BP,MF,CC)
    go_graph <- graph_from_data_frame( all.parents, vertices=terms )
    return(go_graph)
}


##comparison=1;methods=c("fisher","gsva","camera");nterms=200;ntop=20;fdr=0.20
pgx.getSigGO <- function(ngs, comparison, methods=NULL, fdr=0.20, nterms=500, ntop=100)
{
    require(GO.db)
    require(igraph)
    ##if(is.null(ngs)) ngs <- isolate(inputData())
    mx = ngs$gset.meta$meta[[comparison]]
    jj = grep("^GO",rownames(mx))
    if(length(jj)==0) {
        cat("WARNING:: no GO terms in gset.meta$meta!!")
        return(NULL)
    }
    mx = mx[jj,]
    dim(mx)

    ## All methods????
    if(is.null(methods)) {
        methods <- colnames(unclass(mx$p))
    }
    methods

    ## recalculate meta values
    ##fx = as.matrix(mx[,paste0("fx.",methods),drop=FALSE])
    ##pv = as.matrix(mx[,paste0("p.",methods),drop=FALSE])
    ##qv = as.matrix(mx[,paste0("q.",methods),drop=FALSE])
    pv = unclass(mx$p)[,methods,drop=FALSE]
    qv = unclass(mx$q)[,methods,drop=FALSE]
    fc = unclass(mx$fc)[,methods,drop=FALSE]
    pv[is.na(pv)] = 0.999
    qv[is.na(qv)] = 0.999
    fc[is.na(fc)] = 0
    score = fc * (-log10(qv))
    dim(pv)
    if(NCOL(pv)>1) {
        ss.rank <- function(x) scale(sign(x)*rank(abs(x),na.last="keep"),center=FALSE)
        fc = rowMeans(scale(fc,center=FALSE),na.rm=TRUE)
        pv = apply(pv,1,max,na.rm=TRUE)
        qv = apply(qv,1,max,na.rm=TRUE)
        score = rowMeans(apply(score, 2, ss.rank),na.rm=TRUE)
    }

    ##sig = cbind( score=score, fx=fc, pv=pv, qv=qv)
    vinfo = data.frame( geneset=rownames(mx), score=score, fc=fc, pv=pv, qv=qv)
    colnames(vinfo) = c("geneset","score","fc","pv","qv")  ## need
    head(vinfo)
    remove(fc)

    terms <- toTable(GOTERM)[,2:5]
    colnames(terms)[1] = "go_id"
    terms <- terms[ !duplicated(terms[,1]), ]
    rownames(terms) = terms[,1]
    has.goid = all(grepl(")$",rownames(vinfo)))
    if(has.goid) {
        ## rownames have GO ID at the end
        go_id = gsub(".*\\(|\\)$","",rownames(vinfo))
        go_id = gsub("GO_|GO","",go_id)
        go_id = paste0("GO:",go_id)
        rownames(vinfo) = go_id
        vinfo = cbind( vinfo, terms[match(go_id, terms$go_id),] )
    } else {
        ## rownames have no GO ID (downloaded from from MSigDB)
        vv = sub("GO_|GOCC_|GOBP_|GOMF_","",vinfo$geneset)
        idx = match(vv, gsub("[ ]","_",toupper(terms$Term)))
        jj = which(!is.na(idx))
        vinfo = cbind( vinfo[jj,], terms[idx[jj],] )
        rownames(vinfo) = vinfo$go_id
    }
    dim(vinfo)
    vinfo = vinfo[which(!is.na(vinfo$go_id)),]

    ## Get full GO graph and assign node prizes
    go_graph <- getGOgraph()
    V(go_graph)$value = rep(0,length(V(go_graph)))
    V(go_graph)[vinfo$go_id]$foldchange = vinfo$fc
    V(go_graph)[vinfo$go_id]$qvalue = vinfo$qv

    ##!!!!!!!!!!!!!!!!!!! THIS DEFINES THE SCORE !!!!!!!!!!!!!!!!!
    ## Value = "q-weighted fold-change"
    V(go_graph)[vinfo$go_id]$value = vinfo$fc * (1 - vinfo$qv)**1 

    ##v1 <- sig.terms[1]
    get.vpath <- function(v1) {
        shortest_paths(go_graph, v1, "all")$vpath[[1]]
    }
    get.pathscore <- function(v1) {
        sp = shortest_paths(go_graph, v1, "all")$vpath[[1]]
        sp
        sum((V(go_graph)[sp]$value))
    }

    ##fdr=0.20;ntop=20;nterms=200
    sig.terms10 = head(rownames(vinfo)[order(vinfo$qv)],10)
    sig.terms = rownames(vinfo)[which(vinfo$qv <= fdr)]
    sig.terms = unique(c(sig.terms, sig.terms10))
    sig.terms = head(sig.terms[order(vinfo[sig.terms,"qv"])],nterms)  ## maximum number
    length(sig.terms)

    pathscore = sapply(sig.terms, get.pathscore)  ## SLOW!!!
    length(pathscore)
    top.terms = head(sig.terms[order(-abs(pathscore))],ntop)
    head(top.terms)

    ## total subgraph
    vv = unique(unlist(sapply(top.terms, get.vpath)))
    vv = V(go_graph)$name[vv]
    sub1 = induced_subgraph(go_graph, vv)
    score1 = (pathscore/max(abs(pathscore),na.rm=TRUE))[V(sub1)$name]
    ##score1[is.na(score1)] = 0
    V(sub1)$score = pathscore[V(sub1)$name]
    V(sub1)$color = bluered(32)[16 + round(15*score1)]
    V(sub1)$label = vinfo[V(sub1)$name,"Term"]
    ## V(sub1)$size = scale(pathscore[V(sub1)$name],center=FALSE)

    return(sub1)
}

##===================================================================================
##============================= other graph functions ===============================
##===================================================================================

##k=NULL;mc.cores=2
hclustGraph <- function(g, k=NULL, mc.cores=2)
{
    ## Hierarchical clustering of graph using iterative Louvain
    ## clustering on different levels. If k=NULL iterates until
    ## convergences.
    ##
    require(parallel)
    idx = rep(1, length(V(g)))
    K = c()
    maxiter=100
    if(!is.null(k)) maxiter=k
    iter=1
    ok=1
    idx.len = -1
    while( iter <= maxiter && ok ) {
        old.len = idx.len
        newidx0 = newidx = idx
        i=idx[1]
        if(mc.cores>1 && length(unique(idx))>1) {
            idx.list = tapply(1:length(idx),idx,list)
            mc.cores
            system.time( newidx0 <- mclapply(idx.list, function(ii) {
                subg = induced_subgraph(g, ii)
                subi = cluster_louvain(subg)$membership
                return(subi)
            }, mc.cores=mc.cores) )
            newidx0 = lapply(1:length(newidx0), function(i) paste0(i,"-",newidx0[[i]]))
            newidx0 = as.vector(unlist(newidx0))
            newidx = rep(NA,length(idx))
            newidx[as.vector(unlist(idx.list))] = newidx0
        } else {
            for(i in unique(idx)) {
                ii = which(idx==i)
                subg = induced_subgraph(g, ii)
                subi = cluster_louvain(subg)$membership
                newidx[ii] = paste(i,subi,sep="-")
            }
        }
        vv = names(sort(table(newidx),decreasing=TRUE))
        idx = as.integer(factor(newidx, levels=vv))
        K = cbind(K, idx)
        idx.len = length(table(idx))
        ok = (idx.len > old.len)
        iter = iter+1
    }
    if(NCOL(K)==1) K <- matrix(K, ncol=1)
    rownames(K) = V(g)$name
    if(!ok && is.null(k)) K = K[,1:(ncol(K)-1),drop=FALSE]
    dim(K)
    ##K = K[,1:(ncol(K)-1)]
    colnames(K) <- NULL
    return(K)
}
