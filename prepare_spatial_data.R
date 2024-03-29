# ROFSim - Transformer 0 - Prepare Spatial Data

# Set transformer name
transformerName <-"Prepare Spatial Data"

# Packages ----------------------------------------------------------------

library(rsyncrosim)
library(caribouMetrics)
library(raster)
library(sf)
library(dplyr)
library(tidyr)
library(purrr)

localDebug = F
if(!localDebug){
  # Load environment
  e <- ssimEnvironment()
  myLib <- ssimLibrary()
  mySce <- scenario()
  # Source the helpers
  source(file.path(e$PackageDirectory, "helpers.R"))
  
}else{
  e=list()
  e$PackageDirectory = "C:/Users/HughesJo/Documents/SyncroSim/Packages/ROFSim"
  t = try(source(file.path(e$PackageDirectory, "helpers.R")),silent=T) #this will throw Error in .local(.Object, ...) : A library name is required. Don't worry about it.
  source("./scripts/loadSSimLocalForDebug.R") #run outside of SSim for debugging caribouMetrics package
}

# Get all datasheets ------------------------------------------------------

myDatasheetsNames <- c("RasterFile", 
                       "ExternalFile", 
                       "RunCaribouRange", 
                       "CaribouModelOptions",
                       "CaribouDataSource")

loadDatasheet <- function(name){
  sheet <- tryCatch(
    {
      datasheet(mySce, name = name, lookupsAsFactors = FALSE, 
                optional = TRUE)
    },
    error = function(cond){
      return(NULL)
    }, 
    warning = function(cond){
      return(NULL)
    }
  )
}

allParams <- lapply(myDatasheetsNames, loadDatasheet)
names(allParams) <- myDatasheetsNames

# Modify the source data table
allParams$CaribouDataSourceWide <- allParams$CaribouDataSource %>% 
  pivot_longer(values_to = "VarID", names_to = "CaribouVarID", 
               cols=tidyselect::all_of(names(allParams$CaribouDataSource))) %>% 
  rowwise() %>% 
  mutate(type=ifelse(grepl("Raster", CaribouVarID, fixed=TRUE), "raster", "shapefile")) %>% 
  ungroup() %>% drop_na() %>% as.data.frame()

# Get variables -----------------------------------------------------------

# not sure what the point is this just adds the type but type is already separate
# if (nrow(allParams$RasterFile > 0)){
#   allParams$RasterFile <- allParams$RasterFile %>% 
#     left_join(filter(allParams$CaribouDataSourceWide, type=="raster"), 
#               by = c("RastersID" = "VarID")) %>% 
#     as.data.frame()
# }
# 
# if (nrow(allParams$ExternalFile > 0)){
#   allParams$ExternalFile <- allParams$ExternalFile %>% 
#     left_join(filter(allParams$CaribouDataSourceWide, type == "shapefile"), 
#               by = c("PolygonsID" = "VarID")) %>% 
#     as.data.frame()
# }

# get landcover from first timestep
landCoverPth <- filter(allParams$RasterFile, RastersID == "Provincial Land Cover") %>%
  filter(Timestep == min(Timestep) | is.na(Timestep)) %>% 
  mutate(names = paste0(gsub(" ", "_", RastersID), 
                        "_iter_", Iteration,
                        "_ts_", Timestep))

landCoverName <- landCoverPth$names

landCoverPth <- landCoverPth %>% 
  pull(Filename)

# get projectPoly
projectPolyPth <- filter(allParams$ExternalFile, PolygonsID == "Study Area") %>% 
  mutate(names = paste0(gsub(" ", "_", PolygonsID), 
                        "_iter_", Iteration,
                        "_ts_", Timestep))

projectPolyName <- projectPolyPth$names

projectPolyPth <- projectPolyPth$File

# get linear features and make sublists that are appropriate for timesteps 

# Always combines linearFeats that are time step 0 and user needs to know to
# give a specific timestep if they want to overwrite it later. This only works
# if only one type of linFeat changes overtime
linFeatsList <- filter(allParams$ExternalFile, PolygonsID == "Linear Features")

if(nrow(linFeatsList) > 0){
  linFeatsList <- linFeatsList %>% 
    rename(ID = PolygonsID) %>% 
    bind_rows(filter(allParams$RasterFile, RastersID == "Linear Features") %>% 
                rename(ID = RastersID)) %>% 
    mutate(Timestep = ifelse(is.na(Timestep), 0, Timestep)) %>%
    rename(PolygonsID = ID) %>% 
    split(.$Timestep)
  
  # add linFeats in 0 Timestep to all the other timesteps
  # this is a lot of copies that will end up on disk... is there a better way?
  if(length(linFeatsList[-which(names(linFeatsList) == "0")]) > 0){
    linFeatsList <- map(linFeatsList[-which(names(linFeatsList) == "0")],
                        ~bind_rows(splice(.x, linFeatsList[which(names(linFeatsList) == "0")]))) 
  }
  
  linFeatsList <- linFeatsList %>% 
    map(~mutate(.x, 
                Timestep = ifelse(max(Timestep) == 0, NA_real_, max(Timestep)), 
                names = paste0(gsub(" ", "_", PolygonsID), 
                               "_iter_", Iteration,
                               "_ts_", Timestep))) 
  
  linFeatsListNames <- linFeatsList %>% splice() %>% bind_rows() %>%
    pull(names) %>% unique()
  
  # need to make one version that will stay vector and one that will be raster
  linFeatsListLines <- linFeatsList %>% 
    map(~pull(.x, File) %>% as.list()) %>% 
    set_names(paste0(linFeatsListNames, "_lines"))
  
  linFeatsListRast <- linFeatsList %>% 
    map(~pull(.x, File) %>% as.list()) %>% 
    set_names(paste0(linFeatsListNames, "_rast"))
} else {
  linFeatsListLines <- NULL
  linFeatsListRast <- NULL
}

# get just roads for Bird models
roadsOnly <- map(linFeatsListRast, ~map(., ~grep("road", .x, value = TRUE))) %>% 
  map(discard, is_empty) %>%
  flatten() %>% 
  set_names(gsub("Linear_Features", "Roads", names(.)))

# make other filenames into named list
polyFiles <- allParams$ExternalFile %>% 
  filter(!PolygonsID %in% c("Linear Features", "Study Area")) %>% 
  mutate(names = paste0(gsub(" ", "_", PolygonsID), 
                        "_iter_", Iteration,
                        "_ts_", Timestep))

polyFiles <- polyFiles %>% 
  pull(File) %>% as.list() %>% 
  set_names(polyFiles$names)

# get eskers for caribouHabitat separately so that it will have res of 400 while
# others match landcover
Eskers400 <- polyFiles[which(grepl("Esker", names(polyFiles)))] %>% 
  set_names(gsub("Eskers", "Eskers400", names(.)))

rasterFiles <- allParams$RasterFile %>% 
  filter(Filename != landCoverPth) %>% 
  mutate(names = paste0(gsub(" ", "_", RastersID), 
                        "_iter_", Iteration,
                        "_ts_", Timestep))

rasterFiles <- rasterFiles %>% 
  pull(Filename) %>% as.list() %>% 
  set_names(rasterFiles$names)

allSpatialInputs <- loadSpatialInputs(
  projectPoly = projectPolyPth, 
  refRast = landCoverPth,
  inputsList = splice(linFeatsListLines,
                      linFeatsListRast,
                      rasterFiles, 
                      polyFiles, 
                      roadsOnly, 
                      Eskers400) %>% compact(),
  convertToRast = c(names(roadsOnly),
  names(polyFiles)[which(grepl("Esker", names(polyFiles)))]),
  convertToRastDens = c(names(linFeatsListRast), 
                    names(Eskers400)),
  useTemplate = c(names(linFeatsListRast), 
                  names(Eskers400))
)

# walk2(allSpatialInputs, names(allSpatialInputs), ~plot(.x, main = .y))

# write raster and shp files 
writeToFile <- function(x, dirPth, filePth){
  if(is(x, "Raster")){
    writeRaster(x, file.path(dirPth, filePth), format = "GTiff", overwrite = TRUE)
  }
  if(is(x, "sf")){
    write_sf(x, file.path(dirPth, paste0(filePth, ".shp")))
  }
}

# replace refRast with landCover name
names(allSpatialInputs)[which(names(allSpatialInputs) == "refRast")] <- landCoverName

# remove buffered poly and rename projectPoly 
allSpatialInputs[["projectPoly"]] <- NULL
names(allSpatialInputs)[which(names(allSpatialInputs) == "projectPolyOrig")] <- projectPolyName

walk2(allSpatialInputs, names(allSpatialInputs), writeToFile, 
      dirPth = e$TransferDirectory)

# make tables to save to datasheet
FilesOut <- data.frame(
  TransformerID = transformerName,
  Iteration = regmatches(names(allSpatialInputs),
                         regexpr("(?<=_iter_)NA|(?<=_iter_)\\d*",
                                 names(allSpatialInputs), perl = TRUE)),
  Timestep = regmatches(names(allSpatialInputs),
                        regexpr("(?<=_ts_)NA|(?<=_ts_)\\d*",
                                names(allSpatialInputs), perl = TRUE)),
  ID = gsub("_", " ", gsub("_iter.*", "", names(allSpatialInputs))),
  Filename = file.path(e$TransferDirectory,
                       paste0(names(allSpatialInputs), 
                              ifelse(map_lgl(allSpatialInputs, is, "Raster"), 
                                     ".tif", ".shp"))),
  type = ifelse(map_lgl(allSpatialInputs, is, "Raster"), 
                "raster", "sf") %>% as.factor()
) %>% 
  mutate(Iteration = ifelse(Iteration == "NA", NA_real_, Iteration),
         Timestep = ifelse(Timestep == "NA", NA_real_, Timestep)) %>%
  split(.$type)
  
saveDatasheet(ssimObject = mySce, name = "RasterFile",
              data = FilesOut$raster %>% select(-type, RastersID = ID))

saveDatasheet(ssimObject = mySce, name = "ExternalFile",
              data = FilesOut$sf %>% 
                select(-type, PolygonsID = ID, File = Filename))
