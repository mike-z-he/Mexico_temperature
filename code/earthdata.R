suppressPackageStartupMessages(
   {library(data.table)
    library(raster)
    library(rgdal)
    library(gdalUtils)
    library(future.apply)
    library(stringr)
    library(httr)
    library(pbapply)})

source("common.R")

satellite.dir = file.path(data.root, "satellite")
dir.create(satellite.dir, showWarnings = F)

satellite.codes = c(terra = "MOD", aqua = "MYD")
satellite.product.codes = c(temperature = "11A1", vegetation = "13A3")
satellite.tiles = c("h08v06", "h08v07")
  # https://modis-land.gsfc.nasa.gov/MODLAND_grid.html

full.grid.year = 2012L
  # This needs to be a year for which we have satellite vegetation
  # data, but the exact value shouldn't matter much.

full.satellite.grid = function()
    rbindlist(Map(read.satellite.file,
        full.grid = T, product = "vegetation",
        grep(value = T, "\\.A\\d{4}001\\.[^/]+$",
            satellite.paths("aqua", "vegetation", full.grid.year))))

pm(fst = T,
get.satellite.data <- function(satellite, product, the.year)
  # N.B. This function implicitly uses `master.grid`, from `modeling.R`.
  # It's not passed in as an argument so it's not serialized by
  # `pairmemo`.
   {stopifnot(satellite %in% c("terra", "aqua"))
    stopifnot(product %in% c("temperature", "vegetation"))
    message("Loading satellite data: ", paste(satellite, product, the.year))

    month.daynums = c(
        '001', '032', '060', '091', '121', '152',
        '182', '213', '244', '274', '305', '335')

    d = rbindlist(future_lapply(
        satellite.paths(satellite, product, the.year),
        function(fpath)
           {d = read.satellite.file(fpath, product)
            d[, mrow := master.grid[.(floor(d$x), floor(d$y)), mrow]]
            d[, `:=`(x = NULL, y = NULL)]
            d = d[!is.na(mrow)]

            daynum = as.integer(str_match(fpath, "\\.A\\d{4}(\\d{3})")[,2])

            if (product == "temperature")
              # The filename dates are actually in UTC, not our desired
              # working time zone of UTC-06:00. However, I checked a
              # year's worth of overpass times and it seems to work out
              # that each overpass is assigned to the correct UTC-06:00
              # date.
                d[, yday := daynum]
            else
                d[, month := which(month.daynums %in%
                   sprintf('%03d', daynum - c(0, 1)))]}))

    message("Writing satellite data")
    d})

satellite.paths = function(satellite, product, the.year)
   {paths = function() str_subset(
        list.files(file.path(satellite.dir, product), full.names = T),
        fixed(paste0(
            satellite.codes[satellite],
            satellite.product.codes[product],
            ".A", the.year)))
    # Check that there's at least one file for this year. If there
    # isn't, download all the files we need for this year.
    if (!length(paths()))
        download.satellite(satellite, product, the.year)
    paths()}

download.satellite = function(satellite, product, the.year)
   {message(paste("Downloading satellite data for", satellite, product, the.year))

    base.url = sprintf("https://e4ftl01.cr.usgs.gov/MOL%s/%s%s.006",
        substr(toupper(satellite), 1, 1),
        satellite.codes[satellite],
        satellite.product.codes[product])

    # Get daily temperature files and monthly vegetation files.
    dates = (if (product == "temperature")
        do.call(seq, c(
            as.list(as.Date(paste0(the.year, "-", c("01-01", "12-31")))),
            list(by = 1))) else
        as.Date(paste0(the.year, "-", 1:12, "-01")))
    for (date.ix in seq_along(dates))
       {the.dir = sprintf("%s/%s",
            base.url, format(dates[date.ix], "%Y.%m.%d"))
        page = GET(the.dir)
        if (page$status == 404)
           {message(paste("No directory for", dates[date.ix]))
            next}
        stop_for_status(page)

        for (tile in satellite.tiles)
           {fname = str_match(content(page, "text"),
                sprintf('<a href="([^"]+?\\.%s\\.[^"]+\\.hdf)"', tile))[,2]
            if (is.na(fname))
               {message(paste("No data for", dates[date.ix], tile))
                next}
            message("Getting ", fname)
            r = GET(paste0(the.dir, "/", fname),
                authenticate(earthdata.creds()[1], earthdata.creds()[2]))
            stop_for_status(r)
            dir.create(file.path(satellite.dir, product), showWarnings = F)
            writeBin(content(r, "raw"),
                file.path(satellite.dir, product, fname))}}}

read.satellite.file = function(fpath, product, full.grid = F)
   {vars = list(
        temperature = c(
            temp.day = "LST_Day_1km",
            temp.night = "LST_Night_1km"),
        vegetation = c(ndvi = "1 km monthly NDVI"))[[product]]
    subdatasets = paste(sep = ":",
        "HDF4_EOS:EOS_GRID",
        fpath,
        c(temperature = "MODIS_Grid_Daily_1km_LST",
            vegetation = "MOD_Grid_monthly_1km_VI")[product],
        unname(vars))
    g = do.call(cbind, lapply(subdatasets, function(x)
        readGDAL(x, silent = T)))
    if (full.grid)
        g$band1 = 1
    g = suppressWarnings(as(g, "SpatialPointsDataFrame"))
    if (full.grid)
       {d = as.data.table(spTransform(g,
            "+proj=longlat +datum=WGS84 +ellps=WGS84 +towgs84=0,0,0"))
        d[, band1 := NULL]
        setnames(d, c("x", "y"), c("lon", "lat"))
        d[, c("x_sinu", "y_sinu") := as.data.frame(g)[, c("x", "y")]]
        d = d[order(lon, lat)]}
    else
       {d = as.data.table(g)
        setnames(d, str_subset(colnames(d), "band"), names(vars))
        d = d[rowSums(!is.na(d[, mget(names(vars))])) > 0]
        if (product == "vegetation")
           {# The scale factor has already been applied, but by
            # multiplication instead of division, so divide by the
            # square.
            gi = paste(gdalinfo(subdatasets), collapse = " ")
            scale.factor = as.numeric(regmatches(gi,
                regexec(" scale_factor=(\\d+)", gi))[[1]][2])
            d$ndvi = d$ndvi / scale.factor^2
            # Missing points have already been thrown out.
            stopifnot(!anyNA(d))}}
    d}

pm(get.elevation <- function()
   {message("Joining elevation files")
    elev = do.call(mosaic, c(
        list(fun = mean, na.rm = T),
        lapply(elevation.paths(), raster)))
    message("Filtering")
    incr = (res(elev)[1] * 1000) / (30 * 2)
      # resolution, 1000m, div by 30m,
      # div by 2 for radius instead of diameter
    res.grow.factor = 5
    elev = focal(x = elev, w = focalWeight(elev,
        c(res(elev)[1] * res.grow.factor, incr), "Gauss"))
    message("Reading all")
    elev = readAll(elev)
    message("Saving")
    elev})

elevation.paths = function()
  # Gets the paths to elevation files, downloading them if necessary.
   {base.url = "https://e4ftl01.cr.usgs.gov/MEASURES/SRTMGL1.003/2000.02.11"
    squares = as.data.table(with(study.area(), expand.grid(
        lon = floor(left) : ceiling(right),
        lat = floor(bottom) : ceiling(top))))
    squares = squares[!(lon == -97 & lat == 21)]
      # This square is all water, so there's no elevation file for it.
    elevation.dir = file.path(satellite.dir, "elevation")
    dir.create(elevation.dir, showWarnings = F)
    for (i in 1 : nrow(squares))
       {fname = sprintf("N%02dW%03d.SRTMGL1.hgt.zip",
            squares[i, lat],
            -squares[i, lon])
        if (file.exists(file.path(elevation.dir, fname)))
            next
        message("Downloading ", fname)
        r = GET(paste0(base.url, "/", fname),
            authenticate(earthdata.creds()[1], earthdata.creds()[2]))
        stop_for_status(r)
        writeBin(content(r, "raw"), file.path(elevation.dir, fname))}
    list.files(elevation.dir, full = T)}

earthdata.creds = function()
   {creds = Sys.getenv(names = F,
        c("EARTHDATA_USERNAME", "EARTHDATA_PASSWORD"))
    if (any(creds == ""))
        stop("You need to set the environment variables EARTHDATA_USERNAME and EARTHDATA_PASSWORD. If you don't have an account, you can get one at https://urs.earthdata.nasa.gov/users/new")
    creds}
