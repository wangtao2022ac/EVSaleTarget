# Set working directory
work_dir <- "C:/Users/Desktop" # change your directory here
setwd(work_dir)

# Load required packages
library(readr)
library(dplyr)
library(xml2)
library(stringr)
library(tidyr)

# 1. Read input data files with error checking
tryCatch({
  ev_target <- read_csv(file.path(work_dir, "EVTarget.csv"))
  assumptions <- read_csv(file.path(work_dir, "Assumptions on annual travel per vehicle and load factor.csv"))
}, error = function(e) {
  stop("Error reading input files. Please check if files exist and are accessible: ", e$message)
})

# 2. Create function for naming minicam-energy-input
create_minicam_energy_input <- function(supplysector, year) {
  transport_type <- if(str_detect(supplysector, "^trn_freight")) {
    "freight"
  } else if(str_detect(supplysector, "^trn_pass")) {
    "pass"
  } else {
    stop("Invalid supplysector format: ", supplysector)
  }
  paste0("EVTarget", year, "_", transport_type)
}

# 3. Get all possible combinations
# Get unique combinations of technology types
unique_combinations <- assumptions %>%
  select(supplysector, tranSubsector, stub.technology) %>%
  distinct()

# Get all unique regions and years
unique_regions <- unique(ev_target$region)
unique_years <- unique(ev_target$year)

# Verify data completeness
if(length(unique_regions) == 0 || length(unique_years) == 0) {
  stop("Missing regions or years in input data")
}

# Create all possible combinations using Cartesian product
all_combinations <- expand.grid(
  region = unique_regions,
  year = unique_years,
  stringsAsFactors = FALSE
) %>%
  as_tibble() %>%
  merge(unique_combinations, by = NULL)

# 4. Calculate coefficients for BEV
bev_data <- ev_target %>%
  inner_join(
    assumptions %>% filter(stub.technology == "BEV"), 
    by = c("supplysector", "tranSubsector", "year")
  ) %>%
  mutate(
    minicam_energy_input = mapply(create_minicam_energy_input, supplysector, year),
    coefficient = 1 / `assumptions on annual travel per vehicle` * `EV_Sale_Target(%)` * 1000000
  ) %>%
  select(region, year, supplysector, tranSubsector, coefficient, minicam_energy_input)

# Verify BEV data calculations
if(nrow(bev_data) == 0) {
  stop("No BEV data generated. Please check input data.")
}

# 5. Generate StubTranTechCoef.csv
# Join all combinations with BEV data and set market_name to region name
stub_tran_tech_coef <- all_combinations %>%
  left_join(bev_data, 
            by = c("region", "year", "supplysector", "tranSubsector")) %>%
  mutate(
    minicam_energy_input = mapply(create_minicam_energy_input, supplysector, year),
    market_name = region  # Set market_name to region name
  ) %>%
  arrange(region, supplysector, tranSubsector, stub.technology, year)

# Save StubTranTechCoef.csv
write_csv(stub_tran_tech_coef, file.path(work_dir, "StubTranTechCoef.csv"))

# 6. Generate StubTranTechRES.csv (BEV only)
stub_tran_tech_res <- ev_target %>%
  inner_join(
    assumptions %>% 
      filter(stub.technology == "BEV"),
    by = c("supplysector", "tranSubsector", "year")
  ) %>%
  mutate(
    stub.technology = "BEV",
    res.secondary.output = mapply(create_minicam_energy_input, supplysector, year),
    output.ratio = 1 / `assumptions on annual travel per vehicle` / `load factors` * 1000000 / 1000000000,
    pMultiplier = 1000000000
  ) %>%
  select(
    region,
    supplysector,
    tranSubsector,
    stub.technology,
    year,
    res.secondary.output,
    output.ratio,
    pMultiplier
  )

# Verify RES data
if(nrow(stub_tran_tech_res) == 0) {
  stop("No RES data generated. Please check input data.")
}

# Save StubTranTechRES.csv
write_csv(stub_tran_tech_res, file.path(work_dir, "StubTranTechRES.csv"))

# 7. Create XML document
create_new_xml <- function(coef_data, res_data) {
  # Create root node
  doc <- xml_new_document()
  scenario <- xml_add_child(doc, "scenario")
  
  # Add world node
  world <- xml_add_child(scenario, "world")
  
  # Process data by region
  regions <- unique(coef_data$region)
  
  for(reg in regions) {
    region_node <- xml_add_child(world, "region", name = reg)
    
    # Get data for current region
    region_data <- coef_data %>% filter(region == reg)
    
    # Process by supplysector
    for(sector in unique(region_data$supplysector)) {
      sector_node <- xml_add_child(region_node, "supplysector", name = sector)
      sector_data <- region_data %>% filter(supplysector == sector)
      
      # Process by tranSubsector
      for(subsector in unique(sector_data$tranSubsector)) {
        subsector_node <- xml_add_child(sector_node, "tranSubsector", name = subsector)
        subsector_data <- sector_data %>% filter(tranSubsector == subsector)
        
        # Process each technology
        for(tech in unique(subsector_data$stub.technology)) {
          tech_node <- xml_add_child(subsector_node, "stub-technology", name = tech)
          tech_data <- subsector_data %>% filter(stub.technology == tech)
          
          # Process each year
          for(yr in unique(tech_data$year)) {
            period_node <- xml_add_child(tech_node, "period", year = as.character(yr))
            
            # Add minicam-energy-input node
            current_row <- tech_data %>% filter(year == yr)
            energy_input <- xml_add_child(period_node, "minicam-energy-input",
                                          name = current_row$minicam_energy_input)
            xml_add_child(energy_input, "coefficient", current_row$coefficient)
            xml_add_child(energy_input, "market-name", reg)  # Use region name as market-name
            
            # Add res-secondary-output node for BEV only
            if(tech == "BEV") {
              res_row <- res_data %>% 
                filter(region == reg,
                       supplysector == sector,
                       tranSubsector == subsector,
                       year == yr)
              
              if(nrow(res_row) > 0) {
                res_output <- xml_add_child(period_node, "res-secondary-output",
                                            name = res_row$res.secondary.output)
                xml_add_child(res_output, "output-ratio", res_row$output.ratio)
                xml_add_child(res_output, "pMultiplier", res_row$pMultiplier)
              }
            }
          }
        }
      }
    }
    
    # Get transport types for current region (freight/pass)
    transport_types <- unique(region_data$supplysector) %>%
      sapply(function(x) {
        if(str_detect(x, "^trn_freight")) {
          "freight"
        } else if(str_detect(x, "^trn_pass")) {
          "pass"
        }
      }) %>%
      unique()
    
    # Add policy-portfolio-standard sections
    years <- c(2025, 2030, 2035, 2040, 2045, 2050, 2055, 2060)
    for(yr in years) {
      for(transport_type in transport_types) {
        pps_node <- xml_add_child(region_node, "policy-portfolio-standard", 
                                  name = paste0("EVTarget", yr, "_", transport_type))
        xml_add_child(pps_node, "market", reg)  # Use region name as market
        xml_add_child(pps_node, "policyType", "RES")
        xml_add_child(pps_node, "constraint", "1", fillout = "1", year = as.character(yr))
      }
    }
  }
  
  return(doc)
}

# 8. Create new XML file with error handling
tryCatch({
  new_xml <- create_new_xml(stub_tran_tech_coef, stub_tran_tech_res)
  write_xml(new_xml, file.path(work_dir, "new_RPS_BEV2.xml"))
}, error = function(e) {
  stop("Error creating XML file: ", e$message)
})

# 9. Print processing completion information and validation
cat("All files have been generated in directory:", work_dir, "\n")
cat("Generated files include:\n")
cat("1. StubTranTechCoef.csv\n")
cat("2. StubTranTechRES.csv\n")
cat("3. new_RPS_BEV.xml\n")

# 10. Data validation output
cat("\nData Validation:\n")
cat("Unique stub.technology categories in Assumptions file:\n")
print(unique(assumptions$stub.technology))
cat("\nUnique stub.technology categories in generated StubTranTechCoef.csv:\n")
print(unique(stub_tran_tech_coef$stub.technology))
cat("\nValidation of market_name settings:\n")
print(unique(stub_tran_tech_coef[c("region", "market_name")]))

# Additional validation checks
cat("\nAdditional Validation Checks:\n")
cat("Number of regions:", length(unique_regions), "\n")
cat("Number of years:", length(unique_years), "\n")
cat("Number of technology types:", length(unique(assumptions$stub.technology)), "\n")
cat("Number of records in StubTranTechCoef.csv:", nrow(stub_tran_tech_coef), "\n")
cat("Number of records in StubTranTechRES.csv:", nrow(stub_tran_tech_res), "\n")