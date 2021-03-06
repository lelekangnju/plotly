#' Convert a layer to a list of traces. Called from gg2list()
#' @param l one layer of the ggplot object
#' @param d one layer of calculated data from ggplot2::ggplot_build(p)
#' @param misc named list of plot info, independent of layer.
#' @return list representing a layer, with corresponding aesthetics, ranges, and groups.
#' @export
layer2traces <- function(l, d, misc) {
  not.na <- function(df){
    na.mat <- is.na(df)
    to.exclude <- apply(na.mat, 1, any)
    df[!to.exclude, ]
  }
  g <- list(geom=l$geom$objname,
            data=not.na(d),
            prestats.data=not.na(l$prestats.data))
  
  # needed for when group, etc. is an expression.
  g$aes <- sapply(l$mapping, function(k) as.character(as.expression(k)))
  # Partial conversion for geom_violin (Plotly does not offer KDE yet)
  if (g$geom == "violin") {
    g$geom <- "boxplot"
    warning("Converting violin plot into boxplot:\n
            probability density estimation is not supported in Plotly yet.")
  }
  
  # geom_smooth() means geom_line() + geom_ribbon()
  # Note the line is always drawn, but ribbon is not if se = FALSE.
  if (g$geom == "smooth") {
    # If smoothLine has been compiled already, consider drawing the ribbon
    if (isTRUE(misc$smoothLine)) {
      misc$smoothLine <- FALSE
      if (isTRUE(l$stat_params$se == FALSE)) {
        return(NULL) 
      } else {
        g$geom <- "smoothRibbon"
        # disregard colour
        g$data <- g$data[!grepl("^colour[.name]?", names(g$data))]
      }
    } else {
      misc$smoothLine <- TRUE
      g$geom <- "smoothLine"
    }
  }
  # histogram is essentially a bar chart with no gaps (after stats are computed)
  if (g$geom == "histogram") {
    g$geom <- "bar"
    bargap <- 0
  }
  
  # For non-numeric data on the axes, we should take the values from
  # the original data.
  for (axis.name in c("x", "y")) {    
    if (!misc$is.continuous[[axis.name]]) {
      aes.names <- paste0(axis.name, c("", "end", "min", "max"))
      aes.used <- aes.names[aes.names %in% names(g$aes)]
      for(a in aes.used) {
        a.name <- paste0(a, ".name")
        col.name <- g$aes[aes.used]
        dtemp <- l$data[[col.name]]
        if (is.null(dtemp)) {
          if (!is.null(g$data[[a.name]])) {
            # Handle the case where as.Date() is passed in aes argument.
            if (class(g$data[[a]]) != class(g$data[[a.name]])) {
              g$data[[a]] <- g$data[[a.name]]
              data.vec <- g$data[[a]]
            }
          }
        } else {
          data.vec <- dtemp
        }
        
        # For some plot types, we overwrite `data` with `prestats.data`.
        pdata.vec <- g$prestats.data[[a]]
        if (inherits(data.vec, "POSIXt")) {
          # Re-create dates from nb seconds
          data.vec <- try(strftime(as.POSIXlt(g$data[[a]], origin=the.epoch),
                                   "%Y-%m-%d %H:%M:%S"), silent=TRUE)
          pdata.vec <- strftime(as.POSIXlt(g$prestats.data[[a]],
                                           origin=the.epoch),
                                "%Y-%m-%d %H:%M:%S")
        } else if (inherits(data.vec, "Date")) {
          # Re-create dates from nb days
          data.vec <- try(strftime(as.Date(g$data[[a]], origin=the.epoch),
                                   "%Y-%m-%d %H:%M:%S"), silent=TRUE)
          pdata.vec <- strftime(as.Date(g$prestats.data[[a]], origin=the.epoch),
                                "%Y-%m-%d %H:%M:%S")
        } else if (inherits(data.vec, "factor")) {
          # Re-order data so that Plotly gets it right from ggplot2.
          g$data <- g$data[order(g$data[[a]]), ]
          vec.i <- match(g$data[[a]], as.numeric(data.vec))
          if(anyNA(vec.i)){
            vec.i <- match(g$data[[a.name]], data.vec)
          }
          data.vec <- data.vec[vec.i]
          g$prestats.data <- g$prestats.data[order(g$prestats.data[[a]]), ]
          pvec.i <- match(g$prestats.data[[a]], as.numeric(pdata.vec))
          pdata.vec <- pdata.vec[pvec.i]
          if (length(pdata.vec) == length(data.vec))
            pdata.vec <- data.vec
          if (!is.factor(pdata.vec))
            pdata.vec <- g$prestats.data[[a.name]]
        }
        g$data[[a]] <- data.vec
        g$prestats.data[[a]] <- pdata.vec
      }
    }
  }
  # use un-named parameters so that they will not be exported
  # to JSON as a named object, since that causes problems with
  # e.g. colour.
  g$params <- c(l$geom_params, l$stat_params)
  # non-ggplot2 params like name are useful for plot.ly and ggplot2
  # places them into stat_params.
  for(p.name in names(g$params)){
    # c("foo") is translated to "foo" in JSON, so instead we use
    # list("foo") which becomes ["foo"]. However we need to make sure
    # that the list does not have names since list(bar="foo") becomes
    # {"bar":"foo"}
    names(g$params[[p.name]]) <- NULL
  }
  
  # Convert complex ggplot2 geoms so that they are treated as special
  # cases of basic geoms. In ggplot2, this processing is done in the
  # draw method of the geoms.
  
  # Every plotly trace has one of these types
  # type=scatter,bar,box,histogramx,histogram2d,heatmap
  
  # for type=scatter, you can define
  # mode=none,markers,lines,lines+markers where "lines" is the
  # default for 20 or more points, "lines+markers" is the default for
  # <20 points. "none" is useful mainly if fill is used to make area
  # plots with no lines.
  
  # marker=list(size,line,color="rgb(54,144,192)",opacity,symbol)
  
  # symbol=circle,square,diamond,cross,x,
  # triangle-up,triangle-down,triangle-left,triangle-right
  
  # First convert to a "basic" geom, e.g. segments become lines.
  convert <- toBasic[[g$geom]]
  basic <- if(is.null(convert)){
    g
  }else{
    convert(g)
  }
  # Then split on visual characteristics that will get different
  # legend entries.
  data.list <- if (basic$geom %in% names(markSplit)) {
    mark.names <- markSplit[[basic$geom]]
    # However, continuously colored points are an exception: they do
    # not need a legend entry, and they can be efficiently rendered
    # using just 1 trace.
    
    # Maybe it is nice to show a legend for continuous points?
    # if(basic$geom == "point"){
    #   to.erase <- names(misc$is.continuous)[misc$is.continuous]
    #   mark.names <- mark.names[!mark.names %in% to.erase]
    # }
    name.names <- sprintf("%s.name", mark.names)
    # split on 'PANEL' to support facets
    is.split <- names(basic$data) %in% c(name.names, "PANEL")
    if(any(is.split)){
      data.i <- which(is.split)
      matched.names <- names(basic$data)[data.i]
      name.i <- name.names %in% matched.names
      invariable.names <- cbind(name.names, mark.names)[name.i,]
      other.names <- !names(basic$data) %in% invariable.names
      vec.list <- basic$data[is.split]
      df.list <- split(basic$data, vec.list, drop=TRUE)
      lapply(df.list, function(df){
        params <- basic$params
        params[invariable.names] <- if (ncol(x <- df[1, invariable.names]) > 0) x else NULL
        list(data=df[other.names], 
             params=params)
      })
    }
  }
  # Split hline and vline when multiple panels or intercepts:
  # Need multiple traces accordingly.
  if (g$geom %in% c("hline", "vline")) {
    intercept <- paste0(ifelse(g$geom == "hline", "y", "x"), "intercept")
    vec.list <- basic$data[c("PANEL", intercept)]
    df.list <- split(basic$data, vec.list, drop=TRUE)
    data.list <- lapply(df.list, function(df) {
      params <- basic$params
      list(data=df,
           params=params)
    })
  }
  
  # case of no legend, if either of the two ifs above failed.
  if(is.null(data.list)){
    data.list <- structure(list(list(data=basic$data, params=basic$params)),
                           names=basic$params$name)
  }
  getTrace <- geom2trace[[basic$geom]]
  if(is.null(getTrace)){
    warning("Conversion not implemented for geom_",
            g$geom, " (basic geom_", basic$geom, "), ignoring. ",
            "Please open an issue with your example code at ",
            "https://github.com/ropensci/plotly/issues")
    return(list())
  }
  traces <- NULL
  names.in.legend <- NULL
  for (data.i in seq_along(data.list)) {
    data.params <- data.list[[data.i]]
    data.params$params$stat.type <- l$stat$objname
    tr <- do.call(getTrace, data.params)
    for (v.name in c("x", "y")) {
      vals <- tr[[v.name]]
      if (length(vals) > 0 && is.na(vals[length(vals)])) {
        tr[[v.name]] <- vals[-length(vals)]
      }
    }
    name.names <- grep("[.]name$", names(data.params$params), value=TRUE)
    not.group <- grep("group", name.names, value=TRUE, invert=TRUE)
    if (length(not.group)) {
      for(a.name in not.group){
        a <- sub("[.]name$", "", a.name)
        tr$sort[[a.name]] <- if (a %in% names(misc$breaks)){
          # Custom breaks were specified.
          a.value <- as.character(data.params$params[[a.name]])
          ranks <- misc$breaks[[a]]
          if (a.value %in% names(ranks)){
            ranks[[a.value]]
          } else {
            Inf # sorts to the end, when there are less breaks than classes.
          }
        } else { # custom breaks were not specified.
          1 # sort them all the same.
        }
      }
      name.list <- data.params$params[not.group]
      tr$name <- paste(unlist(name.list), collapse=".")
      if (length(unique(name.list)) < 2)
        tr$name <- as.character(name.list[[1]])
    }
    dpd <- data.params$data
    if ("PANEL" %in% names(dpd) && nrow(dpd) > 0)
    {
      tr$xaxis <- paste0("x", dpd[1, "COL"])
      tr$yaxis <- paste0("y", dpd[1, "plotly.row"])
    }
    
    if (is.null(tr$name) || tr$name %in% names.in.legend)
      tr$showlegend <- FALSE
    names.in.legend <- c(names.in.legend, tr$name)
    
    # special handling for bars
    if (g$geom == "bar") {
      tr$bargap <- if (exists("bargap")) bargap else "default"
      pos <- l$position$.super$objname
      tr$barmode <- if (pos %in% c("identity", "stack", "fill")) {
        "stack"
      } else "group"
    }
    
    traces <- c(traces, list(tr))
  }
  
  sort.val <- sapply(traces, function(tr){
    rank.val <- unlist(tr$sort)
    if(is.null(rank.val)){
      0
    }else if(length(rank.val)==1){
      rank.val
    }else{
      0
    }
  })
  
  ord <- order(sort.val)
  no.sort <- traces[ord]
  for(tr.i in seq_along(no.sort)){
    s <- no.sort[[tr.i]]$sort
    no.sort[[tr.i]]$showlegend <-
      if (is.numeric(s)) {
        if (s == Inf){
          FALSE
        } else {
          TRUE
        }
      } else { # no legend.
        FALSE
      }
    no.sort[[tr.i]]$sort <- NULL
  }
  # if line portion of geom_smooth was compiled, call layer2traces()
  # again for ribbon portion
  if (isTRUE(misc$smoothLine)) {
    c(layer2traces(l, d, misc), no.sort)
  } else {
    no.sort
  }
}#layer2traces


# Preprocess data and params.
toBasic <- list(
  segment=function(g){
    # Every row is one segment, we convert to a line with several
    # groups which can be efficiently drawn by adding NA rows.
    g$data$group <- 1:nrow(g$data)
    used <- c("x", "y", "xend", "yend")
    others <- g$data[!names(g$data) %in% used]
    g$data <- with(g$data, {
      rbind(cbind(x, y, others),
            cbind(x=xend, y=yend, others))
    })
    group2NA(g, "path")
  },
  rect=function(g){
    g$data$group <- 1:nrow(g$data)
    used <- c("xmin", "ymin", "xmax", "ymax")
    others <- g$data[!names(g$data) %in% used]
    g$data <- with(g$data, {
      rbind(cbind(x=xmin, y=ymin, others),
            cbind(x=xmin, y=ymax, others),
            cbind(x=xmax, y=ymax, others),
            cbind(x=xmax, y=ymin, others))
    })
    g$geom <- "polygon"
    g
  },
  ribbon=function(g) {
    g$data <- ribbon_dat(g$data)
    g$geom <- "polygon"
    g
  },
  path=function(g) {
    group2NA(g, "path")
  },
  line=function(g) {
    g$data <- g$data[order(g$data$x), ]
    group2NA(g, "path")
  },
  boxplot=function(g) {
    # Preserve default colour values usign fill:
    if (!is.null(g$data$fill)) {
      levels(g$prestats.data$fill) <- g$data$fill
      g$prestats.data$fill <- as.character(g$prestats.data$fill)
    }
    g$data <- g$prestats.data
    g
  },
  bar=function(g){
    g <- group2NA(g, "bar")
    g$data <- g$data[!is.na(g$data$y), ]
    g
  },
  contour=function(g) {
    g$data <- g$prestats.data
    g
  },
  density=function(g) {
    g$geom <- "area"
    if (is.null(g$data$fill) && is.null(g$params$alpha)) g$params$alpha <- 0
    if (is.null(g$data$colour)) g$params$colour <- "black"
    g
  },
  density2d=function(g) {
    g$data <- g$prestats.data
    g
  },
  abline=function(g) {
    g$params$xstart <- min(g$prestats.data$globxmin)
    g$params$xend <- max(g$prestats.data$globxmax)
    g
  },
  hline=function(g) {
    if (is.factor(g$data$x)) {
      g$params$xstart <- as.character(sort(g$data$x)[1])
      g$params$xend <- as.character(sort(g$data$x)[length(g$data$x)])
    } else {
      g$params$xstart <- min(g$prestats.data$globxmin)
      g$params$xend <- max(g$prestats.data$globxmax)
    }
    g
  },
  vline=function(g) {
    g$params$ystart <- min(g$prestats.data$globymin)
    g$params$yend <- max(g$prestats.data$globymax)
    g
  },
  point=function(g) {
    if ("size" %in% names(g$data)) {
      g$params$sizemin <- min(g$prestats.data$globsizemin)
      g$params$sizemax <- max(g$prestats.data$globsizemax)
    }
    g
  },
  smoothLine=function(g) {
    if (length(grep("^colour$", names(g$data))) == 0) 
      g$params$colour <- "#3366FF"
    group2NA(g, "path")
  },
  smoothRibbon=function(g) {
    if (is.null(g$params$alpha)) g$params$alpha <- 0.2
    g$data <- ribbon_dat(g$data)
    g$geom <- "polygon"
    g
  }
)

#' Drawing ggplot2 geoms with a group aesthetic is most efficient in
#' plotly when we convert groups of things that look the same to
#' vectors with NA.
#' @param g list of geom info with g$data$group.
#' @param geom change g$geom to this.
#' @export
#' @return list of geom info.
#' @author Toby Dylan Hocking
group2NA <- function(g, geom) {
  poly.list <- split(g$data, g$data$group, drop=TRUE)
  is.group <- names(g$data) == "group"
  poly.na.list <- list()
  forward.i <- seq_along(poly.list)
  ## When group2NA is called on geom_polygon (or geom_rect, which is
  ## treated as a basic polygon), we need to retrace the first points
  ## of each group, see https://github.com/ropensci/plotly/pull/178
  retrace.first.points <- g$geom == "polygon"
  for (i in forward.i) {
    no.group <- poly.list[[i]][, !is.group, drop=FALSE]
    na.row <- no.group[1, ]
    na.row[, c("x", "y")] <- NA
    retrace.first <- if(retrace.first.points){
      no.group[1,]
    }
    poly.na.list[[paste(i, "forward")]] <-
      rbind(no.group, retrace.first, na.row)
  }
  if(retrace.first.points){
    backward.i <- rev(forward.i[-1])[-1]
    for(i in backward.i){
      no.group <- poly.list[[i]][1, !is.group, drop=FALSE]
      na.row <- no.group[1, ]
      na.row[, c("x", "y")] <- NA
      poly.na.list[[paste(i, "backward")]] <- rbind(no.group, na.row)
    }
    if(length(poly.list) > 1){
      first.group <- poly.list[[1]][1, !is.group, drop=FALSE]
      poly.na.list[["last"]] <- rbind(first.group, first.group)
    }
  }
  g$data <- do.call(rbind, poly.na.list)
  if(is.na(g$data$x[nrow(g$data)])){
    g$data <- g$data[-nrow(g$data), ]
  }
  g$geom <- geom
  g
}

# Make a trace for geom_errorbar -> error_y or geom_errorbarh ->
# error_x.
make.errorbar <- function(data, params, xy){
  tr <-
    list(x=data$x,
         y=data$y,
         type="scatter",
         mode="none")
  err.name <- paste0("error_", xy)
  min.name <- paste0(xy, "min")
  max.name <- paste0(xy, "max")
  e <-
    list(array=data[[max.name]]-data[[xy]],
         type="data",
         width=params$width,
         symmetric=TRUE,
         color=if(!is.null(params$colour)){
           toRGB(params$colour)
         }else{
           toRGB(data$colour)
         })
  arrayminus <- data[[xy]]-data[[min.name]]
  if(!isTRUE(all.equal(e$array, arrayminus))){
    e$arrayminus <- arrayminus
    e$symmetric <- FALSE
  }
  tr[[err.name]] <- e    
  tr
}

# function to transform geom_ribbon data into format plotly likes
# (note this function is also used for geom_smooth)
ribbon_dat <- function(dat) {
  n <- nrow(dat)
  o <- order(dat$x)
  o2 <- order(dat$x, decreasing = TRUE)
  used <- c("x", "ymin", "ymax")
  not_used <- setdiff(names(dat), used)
  # top-half of ribbon
  tmp <- dat[o, ]
  others <- tmp[not_used]
  dat1 <- cbind(x = tmp$x, y = tmp$ymax, others)
  dat1[n+1, ] <- cbind(x = tmp$x[n], y = tmp$ymin[n], others[n, ])
  # bottom-half of ribbon
  tmp2 <- dat[o2, ]
  others2 <- tmp2[not_used]
  dat2 <- cbind(x = tmp2$x, y = tmp2$ymin, others2)
  rbind(dat1, dat2)
}

# Convert basic geoms to traces.
geom2trace <- list(
  path=function(data, params) {
    list(x=data$x,
         y=data$y,
         name=params$name,
         text=data$text,
         type="scatter",
         mode="lines",
         line=paramORdefault(params, aes2line, line.defaults))
  },
  polygon=function(data, params){
    g <- list(data=data, geom="polygon")
    g <- group2NA(g, "polygon")
    list(x=g$data$x,
         y=g$data$y,
         name=params$name,
         text=g$data$text,
         type="scatter",
         mode="lines",
         line=paramORdefault(params, aes2line, polygon.line.defaults),
         fill="tozerox",
         fillcolor=toFill(params$fill, ifelse(is.null(params$alpha), 1,
                                              params$alpha)))
  },
  point=function(data, params){
    L <- list(x=data$x,
              y=data$y,
              name=params$name,
              text=data$text,
              type="scatter",
              mode="markers",
              marker=paramORdefault(params, aes2marker, marker.defaults))
    if("size" %in% names(data)){
      L$text <- paste("size:", data$size)
      L$marker$sizeref <- default.marker.sizeref
      # Make sure sizes are passed as a list even when there is only one element.
      s <- data$size
      marker.size <- 5 * (s - params$sizemin)/(params$sizemax - params$sizemin) + 0.25
      marker.size <- marker.size * marker.size.mult
      L$marker$size <- if (length(s) > 1) marker.size else list(marker.size)
      L$marker$line$width <- 0
    }
    if (!is.null(params$shape) && params$shape %in% c(21:25)) {
      L$marker$color <- ifelse(!is.null(params$fill), toRGB(params$fill), "rgba(0,0,0,0)")
      if (!is.null(params$colour))
        L$marker$line$color <- toRGB(params$colour)
      L$marker$line$width <- 1
    }
    if (!is.null(params$shape) && params$shape %in% c(32)) {
      L$visible <- FALSE
    }
    L
  },
  text=function(data, params){
    L <- list(x=data$x,
              y=data$y,
              text=data$label,
              type="scatter",
              mode="text")
    if (!is.null(params$size)) {
      L$textfont$size <- params$size
    }
    if (!is.null(params$colour)) {
      L$textfont$color <- params$colour
    }
    L
  },
  bar=function(data, params) {
    x <- if ("x.name" %in% names(data)) data$x.name else data$x
    if (inherits(x, "POSIXt")) {
      # Convert seconds into milliseconds
      x <- as.numeric(x) * 1000
    } else if (inherits(x, "Date")) {
      # Convert days into milliseconds
      x <- as.numeric(x) * 24 * 60 * 60 * 1000
    }
    L <- list(x=x,
              y=data$y,
              type="bar",
              name=params$name,
              text=data$text,
              marker=list(color=toRGB(params$fill)))
    if (!is.null(params$colour)) {
      L$marker$line <- list(color=toRGB(params$colour))
      L$marker$line$width <- if (is.null(params$size)) 1 else params$size
    }
    if (!is.null(params$alpha)) L$opacity <- params$alpha
    L
  },
  step=function(data, params) {
    list(x=data$x,
         y=data$y,
         name=params$name,
         type="scatter",
         mode="lines",
         line=paramORdefault(params, aes2line, line.defaults))
  },
  tile=function(data, params) {
    list(x=unique(data$x),
         y=unique(data$y),
         z=t(matrix(data$fill.name, nrow=length(unique(data$x)),
                    ncol=length(unique(data$y)))),
         name=params$name,
         type="heatmap",
         mode="lines",
         line=paramORdefault(params, aes2line, line.defaults))
  },
  boxplot=function(data, params) {
    list(y=data$y,
         name=params$name,
         type="box",
         line=paramORdefault(params, aes2line, boxplot.defaults),
         fillcolor=ifelse(!is.null(data$fill), toRGB(data$fill), toRGB("white")))
  },
  contour=function(data, params) {
    L <- list(x=unique(data$x),
              y=unique(data$y),
              z=t(matrix(data$z, nrow=length(unique(data$x)),
                         ncol=length(unique(data$y)))),
              name=params$name,
              type="contour",
              line=paramORdefault(params, aes2line, line.defaults))
    L$contours=list(coloring="lines")
    L
  },
  density2d=function(data, params) {
    L <- list(x=data$x,
              y=data$y,
              name=params$name,
              type="histogram2dcontour",
              line=paramORdefault(params, aes2line, line.defaults))
    L$contours=list(coloring="lines")
    L
  },
  errorbar=function(data, params) {
    make.errorbar(data, params, "y")
  },
  errorbarh=function(data, params) {
    make.errorbar(data, params, "x")
  },
  area=function(data, params) {
    list(x=c(data$x[1], data$x, tail(data$x, n=1)),
         y=c(0, data$y, 0),
         name=params$name,
         type="scatter",
         line=paramORdefault(params, aes2line, ribbon.line.defaults),
         fill="tozeroy",
         fillcolor=toFill(params$fill, ifelse(is.null(params$alpha), 1,
                                              params$alpha)))
  },
  abline=function(data, params) {
    list(x=c(params$xstart, params$xend),
         y=c(params$intercept + params$xstart * params$slope,
             params$intercept + params$xend * params$slope),
         name=params$name,
         type="scatter",
         mode="lines",
         line=paramORdefault(params, aes2line, line.defaults))
  },
  hline=function(data, params) {
    list(x=c(params$xstart, params$xend),
         y=c(unique(data$yintercept), unique(data$yintercept)),
         name=params$name,
         type="scatter",
         mode="lines",
         line=paramORdefault(params, aes2line, line.defaults))
  },
  vline=function(data, params) {
    list(x=c(data$xintercept, data$xintercept),
         y=c(params$ystart, params$yend),
         name=params$name,
         type="scatter",
         mode="lines",
         line=paramORdefault(params, aes2line, line.defaults))
  }
)
