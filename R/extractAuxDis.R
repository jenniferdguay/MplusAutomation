#' Extract Auxiliary condition means and comparisons.
#'
#' To do: add details.
#'
#' @param outfiletext character vector of Mplus output file from which to extract the AUX section
#' @param filename filename of the Mplus output file being processed
#' @return A data frame
#' @importFrom gsubfn strapply
#' @importFrom stats reshape
#' @keywords internal
extractAux <- function(outfiletext, filename) {
  if (isEmpty(outfiletext)) stop("Missing mean equality to parse.\n ", filename)

  ppSection <- getSection("EQUALITY TESTS OF MEANS ACROSS CLASSES USING POSTERIOR PROBABILITY-BASED", outfiletext)
  bchSection <- getSection("EQUALITY TESTS OF MEANS ACROSS CLASSES USING THE BCH PROCEDURE", outfiletext)
  step3Section <- getSection("EQUALITY TESTS OF MEANS ACROSS CLASSES USING THE 3-STEP PROCEDURE", outfiletext)
  dconSection <- getSection("EQUALITY TESTS OF MEANS/PROBABILITIES ACROSS CLASSES", outfiletext)
  
  step3 <- bch <- dcon <- FALSE
  if (!is.null(step3Section)) {
    sectionToParse <- step3Section
    step3 <- TRUE
  } else if (!is.null(bchSection)) {
    sectionToParse <- bchSection
    bch <- TRUE
  } else if (!is.null(dconSection)) {
    dcon <- TRUE
    sectionToParse <- dconSection
  } else if (!is.null(ppSection)) {
    sectionToParse <- ppSection
  } else {
    return(NULL) #model does not contain mean equality check
  }
  
  if (dcon) {
    sectionToParse <- sectionToParse[2:length(sectionToParse)]
    chip_pattern <- "Chi-Square\\s+P-Value\\s+Degrees of Freedom"
  } else if (bch || step3) {    
    #appears this section does not have a pairwise df listed but is otherwise similar
    dfOmnibus <- as.numeric(sub("^.*WITH (\\d+) DEGREE\\(S\\) OF FREEDOM FOR THE OVERALL TEST.*$", "\\1", sectionToParse[1], perl=TRUE))
    dfPairwise <- NA_integer_
    sectionToParse <- sectionToParse[3:length(sectionToParse)]
    chip_pattern <- "Chi-Square\\s+P-Value"
  } else {
    #check for whether there is one or two more trailing lines
    twoGroupsOnly <- grepl("MULTIPLE IMPUTATIONS WITH 1 DEGREE(S) OF FREEDOM FOR THE OVERALL TEST", sectionToParse[1], fixed=TRUE)
    
    if (twoGroupsOnly) {
      dfOmnibus <- 1
      dfPairwise <- NA_integer_
      #drop single df line and blank line
      sectionToParse <- sectionToParse[3:length(sectionToParse)]
    }
    else {
      #get degrees of freedom
      dfLines <- paste(sectionToParse[1:2], collapse=" ")
      dfOmnibus <- as.numeric(sub("^.*MULTIPLE IMPUTATIONS WITH (\\d+) DEGREE\\(S\\) OF FREEDOM FOR THE OVERALL TEST.*$", "\\1", dfLines, perl=TRUE))
      dfPairwise <- as.numeric(sub("^.*AND (\\d+) DEGREE OF FREEDOM FOR THE PAIRWISE TESTS.*$", "\\1", dfLines, perl=TRUE))
      #drop two subsequent df lines and blank line
      sectionToParse <- sectionToParse[2:length(sectionToParse)]
    }
    
    chip_pattern <- "Chi-Square\\s+P-Value"
  }
  
  #need to handle case of 4+ classes, where it becomes four-column output...
  #columnNames <- c("Mean", "S.E.")

  #obtain any section that begins with no spaces (i.e., each variable)
  variableSections <- getMultilineSection("\\S+", sectionToParse, filename, allowMultiple=TRUE, allowSpace=FALSE)

  varnames <- sectionToParse[attr(variableSections, "matchlines")]

  vc <- list()
  vcat <- list()
  vomnibus <- list()
  vpairwise <- list()
  for (v in 1:length(variableSections)) {
    thisSection <- variableSections[[v]]
    if(any(grepl("Prob\\s*S\\.E\\.\\s*Odds Ratio", thisSection))){
      # This is a categorical auxiliary variable, handle accordingly
      thisSection <- thisSection[!thisSection == ""]
      # col_headers <- strsplit(trimws(tolower(gsub("(\\d*\\.\\d*)% CI", "ci_\\1", gsub("(?<=[A-Z])\\.", "", grep("Prob\\s*S\\.E\\.\\s*Odds Ratio", thisSection, value = TRUE), perl = TRUE)))), split = "\\s{2,}")[[1]]
      props <- thisSection[grepl("Class", thisSection, fixed = TRUE) | grepl("Category", thisSection, fixed = TRUE) ]
      props <- strsplit(props, "\\s+")
      lengths <- sapply(props, length)
      if(!(all(c(3, 9) %in% lengths))){
        message("Could not extract categorical conditional variables.")
      }
      labs <- sapply(props[lengths == 3], `[`, 3)
      props <- data.frame(do.call(rbind, props[lengths == 9]))
      props$X3 <- as.integer(props$X3)
      which_lab <- 1
      props$X1[1] <- labs[which_lab]
      for(i in 2:nrow(props)){
        if(!sign(props$X3[i]-props$X3[i-1] > 0)){
          which_lab <- which_lab + 1
        }
        props$X1[i] <- labs[which_lab]
      }
      props <- props[, -2]
      #names(props) <- c("class", "category", col_headers)
      names(props) <- c("class", "category", "prob", "se", "or", "se_or", "ci_lower", "ci_upper")
      
      tests <- thisSection[grepl("Overall test", thisSection, fixed = TRUE) | grepl(" vs. ", thisSection, fixed = TRUE) ]
      tests <- strsplit(tests, "\\s+")
      lengths <- sapply(tests, length)
      tests[lengths == 6] <- lapply(tests[lengths == 6], function(x){
        c(x[1], "", x[2], "", x[c(2,4:6)])
      })
      tests <- data.frame(do.call(rbind, tests))
      tests <- tests[, -c(1,2,4)]
      if(any(grepl("NUMBER OF OBSERVATIONS USED FOR THE AUXILIARY VARIABLE", thisSection, fixed = TRUE))){
        tests <- cbind(tests, n = as.integer(gsub("^.+?(\\d{1,}).*?$", "\\1", grep("NUMBER OF OBSERVATIONS USED FOR THE AUXILIARY VARIABLE", thisSection, fixed = TRUE, value = TRUE))))
      }
      
      names(tests)[1:5] <- c("class", "versus", "chi_square", "p", "df")
      vcat[[varnames[v]]] <- list(parameters = props, tests = tests)
    } else {
      # If it is not categorical, extract the conditional means. This is the 'old' code
      #mean s.e. match
      meanSELine <- grep("^\\s*Mean\\s*S\\.E\\.\\s*$", thisSection, perl=TRUE)
      meanSE_twoColumn <- FALSE
      
      #check for side-by-side output
      if (length(meanSELine) == 0) {
        meanSELine <- grep("^\\s*Mean\\s+S\\.E\\.\\s+Mean\\s+S\\.E\\.\\s*$", thisSection, perl=TRUE)
        if (length(meanSELine) > 0) {
          meanSE_twoColumn <- TRUE #side-by-side output
        } else {
          print(paste("Couldn't match mean and s.e. for variable", varnames[[v]], "It may not be a continous variable. Support for categorical variables has not yet been implemented."))
          next
        }
      }
      
      chiPLine <- grep(paste0("^\\s*", chip_pattern, "\\s*$"), thisSection, perl=TRUE)
      chiP_twoColumn <- FALSE
      
      if (length(chiPLine) == 0L) {
        chiPLine <- grep(paste0("^\\s*", chip_pattern, "\\s+", chip_pattern, "\\s*$"), thisSection, perl=TRUE)
        if (length(chiPLine) > 0) {
          chiP_twoColumn <- TRUE #side-by-side output
        } else {
          message(paste("Couldn't match chi-square and p-value for variable", varnames[[v]], "It may not be a continous variable. Support for categorical variables has not yet been implemented."))
          next
        }
      }
      
      means <- thisSection[(meanSELine[1]+1):(chiPLine[1]-1)]
      chip <- thisSection[(chiPLine[1]+1):length(thisSection)]
      
      #handle cases where there is wide side-by-side output (for lots of classes)
      if (meanSE_twoColumn) {      
        #pre-process means to divide two-column output
        splitMeans <- friendlyGregexpr("Class", means)
        el <- unique(splitMeans$element)
        meansReparse <- c()
        pos <- 1
        for (i in el) {
          match <- splitMeans[splitMeans$element==i, , drop=FALSE]
          if (nrow(match) > 1L) {
            for (j in 1:nrow(match)) {
              #if not on last match for this line, then go to space before j+1 match. Otherwise, end of line
              end <- ifelse(j < nrow(match), match[j+1,"start"] - 1, nchar(means[i]))
              meansReparse[pos] <- trimSpace(substr(means[i], match[j, "start"], end))
              pos <- pos+1
            }
          } else if (nrow(match) == 1L) {
            meansReparse[pos] <- trimSpace(means[i])
            pos <- pos+1
          }
        }
        
        means <- meansReparse
      }
      
      if (chiP_twoColumn) {
        #divide chi square and p section into unique entries for each comparison
        splitChiP <- friendlyGregexpr("(Overall|Class)", chip)
        el <- unique(splitChiP$element)
        chipReparse <- c()
        pos <- 1
        #split into first half of columns and second half
        for (i in el) {
          match <- splitChiP[splitChiP$element==i, , drop=FALSE]
          if (nrow(match) > 1L) {
            for (j in 1:nrow(match)) {
              #if not on last match for this line, then go to space before j+1 match. Otherwise, end of line
              end <- ifelse(j < nrow(match), match[j+1,"start"] - 1, nchar(chip[i]))
              chipReparse[pos] <- trimSpace(substr(chip[i], match[j, "start"], end))
              pos <- pos+1
            }
          } else if (nrow(match) == 1L) {
            chipReparse[pos] <- trimSpace(chip[i])
            pos <- pos+1
          }
        }
        
        chip <- chipReparse
      }
      
      class.M.SE <- strapply(means, "^\\s*Class\\s+(\\d+)\\s+([\\d\\.-]+)\\s+([\\d\\.-]+)", function(class, m, se) {
        return(c(class=as.integer(class), m=as.numeric(m), se=as.numeric(se)))
      }, simplify=FALSE)
      
      #drop nulls
      class.M.SE[sapply(class.M.SE, is.null)] <- NULL
      
      #need to trap overall test versus pairwise comparisons -- this could be much more elegant, but works for now
      overallLine <- grep("^\\s*Overall test\\s+.*$", chip, perl=TRUE)
      if (length(overallLine) > 0L) {
        if (dcon) {
          #DCON output has degrees of freedom inline as a third column
          class.chi.p.omnibus <- strapply(chip[overallLine], "^\\s*Overall test\\s+([\\d\\.-]+)\\s+([\\d\\.-]+)\\s+([\\d\\.-]+)", function(chisq, p, df) {
            #return(c(class1="Overall", class2="", chisq=as.numeric(chisq), p=as.numeric(p)))
            return(c(chisq=as.numeric(chisq), df=as.numeric(df), p=as.numeric(p)))
          }, simplify=FALSE)[[1L]]
        } else {
          class.chi.p.omnibus <- strapply(chip[overallLine], "^\\s*Overall test\\s+([\\d\\.-]+)\\s+([\\d\\.-]+)", function(chisq, p) {
            #return(c(class1="Overall", class2="", chisq=as.numeric(chisq), p=as.numeric(p)))
            return(c(chisq=as.numeric(chisq), df=as.numeric(dfOmnibus), p=as.numeric(p)))
          }, simplify=FALSE)[[1L]]
        }
        chip <- chip[-overallLine] #drop omnibus line from subsequent pairwise parsing
      } else {
        class.chi.p.omnibus <- list()
      }
      
      if (dcon) {
        #DCON output has degrees of freedom inline as a third column
        class.chi.p.pairwise <- strapply(chip, "^\\s*Class\\s+(\\d+)\\s+vs\\.\\s+(\\d+)\\s+([\\d\\.-]+)\\s+([\\d\\.-]+)\\s+([\\d\\.-]+)", function(classA, classB, chisq, p, df) {
          return(c(classA=as.character(classA), classB=as.character(classB), chisq=as.numeric(chisq), df=as.numeric(df), p=as.numeric(p)))
        }, simplify=FALSE)
      } else {
        class.chi.p.pairwise <- strapply(chip, "^\\s*Class\\s+(\\d+)\\s+vs\\.\\s+(\\d+)\\s+([\\d\\.-]+)\\s+([\\d\\.-]+)", function(classA, classB, chisq, p) {
          return(c(classA=as.character(classA), classB=as.character(classB), chisq=as.numeric(chisq), df=as.numeric(dfPairwise), p=as.numeric(p)))
        }, simplify=FALSE)
      }
      
      class.chi.p.pairwise[sapply(class.chi.p.pairwise, is.null)] <- NULL
      
      if (length(class.chi.p.pairwise) > 0L) { class.chi.p.pairwise <- data.frame(do.call("rbind", class.chi.p.pairwise), var=varnames[v]) }
      if (length(class.chi.p.omnibus) > 0L) { class.chi.p.omnibus <- data.frame(cbind(t(class.chi.p.omnibus), var=varnames[v])) }
      
      #build data.frame
      class.M.SE <- data.frame(do.call("rbind", class.M.SE), var=varnames[v])
      vc[[varnames[v]]] <- class.M.SE
      vomnibus[[varnames[v]]] <- class.chi.p.omnibus
      vpairwise[[varnames[v]]] <- class.chi.p.pairwise
    }
    
  }
  ret <- list()
  if(length(vc) > 0){
    allMeans <- data.frame(do.call("rbind", vc), row.names=NULL)
    allMeans <- allMeans[,c("var", "class", "m", "se")]
    
    allMeans <- reshape(allMeans, idvar="var", timevar="class", direction="wide")
    allOmnibus <- data.frame(do.call("rbind", vomnibus), row.names=NULL)
    allMeans <- merge(allMeans, allOmnibus, by="var")
    if (! all(sapply(vpairwise, length) == 0L)) {
      allPairwise <- data.frame(do.call("rbind", vpairwise), row.names=NULL)
      allPairwise$chisq <- as.numeric(as.character(allPairwise$chisq))
      allPairwise$df <- as.integer(as.character(allPairwise$df))
      allPairwise$p <- as.numeric(as.character(allPairwise$p))
      allPairwise <- allPairwise[,c("var", "classA", "classB", "chisq", "df", "p")]
    } else {
      allPairwise <- data.frame(var=factor(character(0)),
                                classA=factor(character(0)),
                                classB=factor(character(0)),
                                chisq=numeric(0),
                                df=numeric(0),
                                p=numeric(0))
    }
    
    ret <- list(overall=allMeans, pairwise=allPairwise)
  }
  if(length(vcat) > 0){
    ret <- c(ret, vcat)
  }
  class(ret) <- c("mplus.auxE", "list")

  return(ret)
}

#' Extract output of R3STEP procedure
#'
#' @param outfiletext character vector of Mplus output file from which to extract the AUX section
#' @param filename filename of the Mplus output file being processed
#' @return A list containing the parsed R3STEP sections
#' @keywords internal
extractR3step <- function(outfiletext, filename) {
  allSections <- list() # holds parameters for all identified sections

  parR3stepSection <- getSection("^TESTS OF CATEGORICAL LATENT VARIABLE MULTINOMIAL LOGISTIC REGRESSIONS USING::^THE 3-STEP PROCEDURE", outfiletext)
  if (is.null(parR3stepSection)) return(allSections) # nothing
  
  # The highest class value is the default reference, so we need to add 1 to the highest alternative reference class number to infer the first class
  classNums <- strapply(parR3stepSection, "Parameterization using Reference Class (\\d+)", as.numeric, empty=NA_integer_, simplify=TRUE)
  firstClass <- max(na.omit(classNums)) + 1
  firstLine <- paste("Parameterization using Reference Class", firstClass) # Add this on the first line so that we parse the structure correctly
  
  parR3stepSection <- c(firstLine, parR3stepSection)
  allSections <- appendListElements(allSections, extractParameters_1section(filename, parR3stepSection, "multinomialTests"))
  
  # odds ratios
  parR3oddsSection <- getSection("^ODDS RATIOS FOR TESTS OF CATEGORICAL LATENT VARIABLE MULTINOMIAL LOGISTIC REGRESSIONS::^USING THE 3-STEP PROCEDURE$", outfiletext)
  
  if (!is.null(parR3oddsSection)) {
    parR3oddsSection <- c(firstLine, parR3oddsSection)
    allSections <- appendListElements(allSections, extractParameters_1section(filename, parR3oddsSection, "multinomialOdds"))
  }
  
  # confidence intervals for 3-step procedure
  ciR3stepSection <- getSection("^CONFIDENCE INTERVALS FOR TESTS OF CATEGORICAL LATENT VARIABLE MULTINOMIAL LOGISTIC REGRESSIONS$::^USING THE 3-STEP PROCEDURE$", outfiletext)

  if (!is.null(ciR3stepSection)) {
    ciR3stepSection <- c(firstLine, ciR3stepSection)
    hline <- detectColumnNames(filename, ciR3stepSection, "confidence_intervals")
    allSections <- appendListElements(allSections, extractParameters_1section(filename, ciR3stepSection, "ci.unstandardized"))
  }
  
  # confidence intervals odds ratios for 3-step procedure
  ciR3stepOddsSection <- getSection("^CONFIDENCE INTERVALS OF ODDS RATIOS FOR TESTS OF CATEGORICAL LATENT VARIABLE MULTINOMIAL$::^LOGISTIC REGRESSIONS USING THE 3-STEP PROCEDURE$", outfiletext)
  
  if (!is.null(ciR3stepOddsSection)) {
    # at present, the CI header is not reprinted in the odds ratio section, so we need to copy-paste header line for parsing
    ciR3stepOddsSection <- c(firstLine, ciR3stepSection[attr(hline, "header_lines")], ciR3stepOddsSection)
    allSections <- appendListElements(allSections, extractParameters_1section(filename, ciR3stepOddsSection, "ci.odds"))
  }
  
  return(allSections)

}
