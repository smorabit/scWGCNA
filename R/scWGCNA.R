#' construct_metacells
#'
#' This function takes a Seurat object and constructs averaged 'metacells' based
#' on neighboring cells.
#' @param seurat_obj A Seurat object
#' @param k Number of nearest neighbors to aggregate. Default = 50
#' @param name A string appended to resulting metalcells. Default = 'agg'
#' @param reduction A dimensionality reduction stored in the Seurat object. Default = 'umap'
#' @param assay Assay to extract data for aggregation. Default = 'RNA'
#' @param slot Slot to extract data for aggregation. Default = 'data'
#' @keywords scRNA-seq
#' @export
#' @examples
#' construct_metacells(pbmc)
construct_metacells <- function(seurat_obj, name='agg', k=50, reduction='umap', assay='RNA', slot='data'){

  reduced_coordinates <- as.data.frame(seurat_obj@reductions[[reduction]]@cell.embeddings)
  nn_map <- FNN::knn.index(reduced_coordinates, k = (k - 1))
  row.names(nn_map) <- row.names(reduced_coordinates)
  nn_map <- cbind(nn_map, seq_len(nrow(nn_map)))
  good_choices <- seq_len(nrow(nn_map))
  choice <- sample(seq_len(length(good_choices)), size = 1,
      replace = FALSE)
  chosen <- good_choices[choice]
  good_choices <- good_choices[good_choices != good_choices[choice]]
  it <- 0
  k2 <- k * 2
  get_shared <- function(other, this_choice) {
      k2 - length(union(cell_sample[other, ], this_choice))
  }
  while (length(good_choices) > 0 & it < 5000) {
      it <- it + 1
      choice <- sample(seq_len(length(good_choices)), size = 1,
          replace = FALSE)
      new_chosen <- c(chosen, good_choices[choice])
      good_choices <- good_choices[good_choices != good_choices[choice]]
      cell_sample <- nn_map[new_chosen, ]
      others <- seq_len(nrow(cell_sample) - 1)
      this_choice <- cell_sample[nrow(cell_sample), ]
      shared <- sapply(others, get_shared, this_choice = this_choice)

      if (max(shared) < 0.9 * k) {
          chosen <- new_chosen
      }
  }

  cell_sample <- nn_map[chosen, ]
  combs <- combn(nrow(cell_sample), 2)
  shared <- apply(combs, 2, function(x) {
      k2 - length(unique(as.vector(cell_sample[x, ])))
  })

  message(paste0("Overlap QC metrics:\nCells per bin: ",
      k, "\nMaximum shared cells bin-bin: ", max(shared),
      "\nMean shared cells bin-bin: ", mean(shared), "\nMedian shared cells bin-bin: ",
      median(shared)))
  if (mean(shared)/k > 0.1)
      warning("On average, more than 10% of cells are shared between paired bins.")

  exprs_old <- GetAssayData(seurat_obj, assay=assay, slot=slot)

  mask <- sapply(seq_len(nrow(cell_sample)), function(x) seq_len(ncol(exprs_old)) %in%
      cell_sample[x, , drop = FALSE])
  mask <- Matrix::Matrix(mask)
  new_exprs <- (exprs_old %*% mask) / k
  colnames(new_exprs) <- paste0(name, '_', 1:ncol(new_exprs))
  rownames(cell_sample) <- paste0(name, '_', 1:ncol(new_exprs))
  colnames(cell_sample) <- paste0('knn_', 1:ncol(cell_sample))

  # make seurat obj:
  seurat_aggr <- CreateSeuratObject(
    counts = new_exprs
  )
  seurat_aggr

}

#' metacells_by_groups
#'
#' This function takes a Seurat object and constructs averaged 'metacells' based
#' on neighboring cells in provided groupings, such as cluster or cell type.
#' @param seurat_obj A Seurat object
#' @param group.by A character vector of Seurat metadata column names representing groups for which metacells will be computed. Default = 'seurat_clusters'
#' @param k Number of nearest neighbors to aggregate. Default = 50
#' @param name A string appended to resulting metalcells. Default = 'agg'
#' @param reduction A dimensionality reduction stored in the Seurat object. Default = 'umap'
#' @param assay Assay to extract data for aggregation. Default = 'RNA'
#' @param slot Slot to extract data for aggregation. Default = 'data'
#' @keywords scRNA-seq
#' @export
#' @examples
#' metacells_by_groups(pbmc)
metacells_by_groups <- function(seurat_obj, group.by=c('seurat_clusters'), k=50, reduction='umap', assay='RNA', slot='data'){
  
  # should replace this apply with something faster
  if(length(group.by) > 1){
    seurat_obj$metacell_grouping <- apply(seurat_obj@meta.data[, group.by], 1, paste, collapse='_')
  } else {
    seurat_obj$metacell_grouping <- seurat_obj@meta.data[[group.by]]
  }

  groupings <- unique(seurat_obj$metacell_grouping)

  # split seurat obj by groupings
  seurat_list <- lapply(groupings, function(x){seurat_obj[,seurat_obj$metacell_grouping == x]})
  names(seurat_list) <- groupings

  # construct metacells
  out <- future_mapply(scWGCNA::construct_metacells, seurat_list, groupings, MoreArgs = list(k=k, reduction=reduction, assay=assay, slot=slot))
  names(out) <- groupings

  # merge seurat objects:
  for(i in 1:length(out)){
    if(length(group.by) > 1){
      cur_groups <- unlist(strsplit(groupings[i], '_'))
      for(j in 1:length(group.by)){
        out[[groupings[i]]]@meta.data[[group.by[j]]] <- cur_groups[j]
      }
    } else{
      out[[groupings[i]]]@meta.data[[group.by]] <- groupings[i]
    }
  }

  seurat_merged <- merge(out[[1]], out[2:length(out)])
  seurat_merged
}
