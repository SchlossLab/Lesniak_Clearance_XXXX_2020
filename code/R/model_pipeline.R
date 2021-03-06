
# Author: Begum Topcuoglu
# Date: 2019-01-14
######################################################################
# Description:
# This script trains and tests the model according to proper pipeline
######################################################################

######################################################################
# Dependencies and Outputs:
#    Model to put to function:
#       1. "L2_Logistic_Regression"
#       2. "L2_Linear_SVM"
#       3. "RBF_SVM"
#       4. "Decision_Tree"
#       5. "Random_Forest"
#       6. "XGBoost"
#    data to put to function:
#         Features: Hemoglobin levels and 16S rRNA gene sequences in the stool
#         Labels: - Colorectal lesions of 490 patients.
#                 - Defined as cancer or not.(Cancer here means: SRN)
#
# Usage:
# Call as source when using the function. The function is:
#   pipeline(data, model)

# Output:
#  A results list of:
#     1. cvAUC and testAUC for 1 data-split
#     2. cvAUC for all hyper-parameters during tuning for 1 datasplit
#     3. feature importance info on first 10 features for 1 datasplit
#     4. trained model as a caret object
######################################################################

######################################################################
#------------------------- DEFINE FUNCTION -------------------#
######################################################################
source("code/R/tuning_grid.R")
source("code/R/permutation_importance.R")
source("code/R/auprc.R")

pipeline <- function(data, model, split_number, outcome=NA, hyperparameters=NULL, level=NA, permutation=TRUE){

  # -----------------------Get outcome variable----------------------------->
  # If no outcome specified, use first column in data
  if(is.na(outcome)){
    outcome <- colnames(data)[1]
  }else{
    # check to see if outcome is in column names of data
    if(!outcome %in% colnames(data)){
      stop(paste('Outcome',outcome,'not in column names of data.'))
    }

		# Let's make sure that the first column in the data frame is the outcome variable
		temp_data <- data.frame(outcome = sample(data[,outcome]))
		colnames(temp_data) <- outcome
		data <- cbind(temp_data, data[, !(colnames(data) %in% outcome)]) # want the outcome column to appear first
  }

  # ------------------Check data for pre-processing------------------------->
  # Data is pre-processed in code/R/setup_model_data.R
  # This removes OTUs with near zero variance and scales 0-1
  # Then generates a correlation matrix
  # Test if data has been preprocessed - range 0-1 and are not all 0s
  feature_summary <- any(c(min(data[,-1]) < 0, 
    max(data[,-1]) > 1, 
    any(apply(data[,-1], 2, sum) == 0)))
  if(feature_summary){
    stop('Data has not been preprocessed, please use "code/R/setup_model_data.R" to preprocess data')
  }

  # ------------------Randomize features----------------------------------->
  # Randomize feature order, to eliminate any position-dependent effects 
  features <- sample(colnames(data[,-1]))
  data <- select(data, one_of(outcome), one_of(features))

  # ----------------------------------------------------------------------->
  # Get outcome variables
  first_outcome = as.character(data[1,outcome])
  outcome_vals = unique(data[,outcome])
  if(length(outcome_vals) != 2) stop('A binary outcome variable is required.')
  second_outcome = as.character(outcome_vals[!outcome_vals == first_outcome])
  print(paste(c('first outcome:','second outcome:'),c(first_outcome,second_outcome)))


  # ------------------80-20 Datasplit for each seed------------------------->
  # Do the 80-20 data-split
  # Stratified data partitioning %80 training - %20 testing
  inTraining <- createDataPartition(data[,outcome], p = .50, list = FALSE)
  train_data <- data[ inTraining,]
  test_data  <- data[-inTraining,]

  #  # Leave out test data by cages
  # Read in cage/sample name from 
  cages <- read_csv(paste0('data/process/', level, '_sample_names.txt')) %>% 
    rowid_to_column() # add row id as column to use to select samples by row number
  test_samples <- cages[-inTraining,]
  #  # leave out cages for testing, setup sample numbers
  #  cv_test_split <- 20
  #  n_test <- round((cv_test_split/100) * 45)
  #  n_cv <- round(((100 - cv_test_split)/100) * 45)
  #  n_cages <- round(n_test/2.81)
  #  test_cages <- sample(unique(cages$cage), n_cages)
  #  test_outcomes <- count(filter(cages, cage %in% test_cages), clearance)
  #  # if all test cases are the same, resample until both outcomes are included
  #  while(all(test_outcomes$n <= 1) | (!length(test_outcomes$n) == 2)){
  #    print('redrawing')
  #      test_cages <- sample(unique(cages$cage), n_cages)
  #      test_outcomes <- count(filter(cages, cage %in% test_cages), clearance)
  #  }
  #  # sample the test and training set to ensure equal numbers and reduce bias of cages with greater number of mice
  #  training_samples <- c(filter(cages, !cage %in% test_cages, clearance == 'Cleared') %>% 
  #      pull(rowid) %>% sample(., round(.6 * n_cv), replace = T),
  #    filter(cages, !cage %in% test_cages, clearance == 'Colonized') %>% 
  #      pull(rowid) %>% sample(., round(0.4 * n_cv), replace = T))
  #  test_samples <- filter(cages, cage %in% test_cages) %>% sample_n(n_test, replace = T)
  #  # if all test cases are the same, resample until both outcomes are included
  #  while(sum(test_samples$clearance == 'Cleared') <= round(0.25 * n_test) | 
  #    sum(test_samples$clearance == 'Colonized') <= round(0.25 * n_test)){
  #    test_samples <- filter(cages, cage %in% test_cages) %>% sample_n(n_test, replace = T)
  #  }
  #  train_data <- data[training_samples, ]
  #  test_data <- data[test_samples$rowid, ]

  # ----------------------------------------------------------------------->

  # -------------Define hyper-parameter and cv settings-------------------->
  # Define hyper-parameter tuning grid and the training method
  # Uses function tuning_grid() in file ('code/learning/tuning_grid.R')
  tune <- tuning_grid(train_data, model, outcome, hyperparameters)
  grid <- tune[[1]]
  method <- tune[[2]]
  cv <- tune[[3]]
  # ----------------------------------------------------------------------->

  # ---------------------------Train the model ---------------------------->
  # ------------------------------- 1. -------------------------------------
  # - We train on the 80% of the full data.
  # - We use the cross-validation and hyper-parameter settings defined above to train
  # ------------------------------- 2. -------------------------------------
  # We use ROC metric for all the models
  # To do that I had to make changes to the caret package functions.
  # The files 'data/caret_models/svmLinear3.R and svmLinear5.R are my functions.
  # I added 1 line to get Decision Values for linear SVMs:
  #
  #           prob = function(modelFit, newdata, submodels = NULL){
  #             predict(modelFit, newdata, decisionValues = TRUE)$decisionValues
  #           },
  #
  # This line gives decision values instead of probabilities and computes ROC in:
  #   1. train function with the cross-validataion
  #   2. final trained model
  # using decision values and saves them in the variable "prob"
  # ------------------------------- 3. --------------------------------------
  # - If the model is logistic regression, we need to add a family=binomial parameter.
  # - If the model is random forest, we need to add a ntree=1000 parameter.
  #         We chose ntree=1000 empirically.
  # ----------------------------------------------------------------------->
  # Make formula based on outcome
  f <- as.formula(paste(outcome, '~ .'))
  print('Machine learning formula:')
  print(f)
  # Start walltime for training model
  tic("train")
  if(model=="L2_Logistic_Regression"){
  print(model)
  trained_model <-  train(f, # label
                          data=train_data, #total data
                          method = method,
                          trControl = cv,
                          metric = "ROC",
                          tuneGrid = grid,
                          family = "binomial")
  }
  else if(model=="Random_Forest"){
      print(model)
      trained_model <-  train(f,
                              data=train_data,
                              method = method,
                              trControl = cv,
                              metric = "ROC",
                              tuneGrid = grid,
                              ntree=1000) # not tuning ntree
  }
  else{
    print(model)
    trained_model <-  train(f,
                            data=train_data,
                            method = method,
                            trControl = cv,
                            metric = "ROC",
                            tuneGrid = grid)
  }
  # Stop walltime for running model
  seconds <- toc()
  # Save elapsed time
  train_time <- seconds$toc-seconds$tic
  # Save wall-time
  write.csv(train_time, file=paste0("data/temp/", level, "/traintime_", model, "_", split_number, ".csv"), row.names=F)
  # ------------- Output the cvAUC and testAUC for 1 datasplit ---------------------->
  # Mean cv AUC value over repeats of the best cost parameter during training
  cv_auc <- getTrainPerf(trained_model)$TrainROC
  # Save all results of hyper-parameters and their corresponding meanAUCs over 100 internal repeats
  results_individual <- trained_model$results
  # ---------------------------------------------------------------------------------->

  # -------------------------- Feature importances ----------------------------------->
  #   if linear: Output the weights of features of linear models
  #   else: Output the feature importances based on random permutation for non-linear models
  # Here we look at the top 20 important features
  if(permutation){
    if(model=="L1_Linear_SVM" || model=="L2_Linear_SVM" || model=="L2_Logistic_Regression"){
      # We will use the permutation_importance function here to:
      #     1. Predict held-out test-data
      #     2. Calculate ROC and AUROC values on this prediction
      #     3. Get the feature importances for correlated and uncorrelated feautures
      roc_results <- permutation_importance(trained_model, test_data, first_outcome, second_outcome, outcome, level, test_samples, split_number)
      test_auc <- roc_results[[1]]  # Predict the base test importance
      feature_importance_non_cor <- roc_results[2] # save permutation results
      # Get feature weights
      feature_importance_cor <- trained_model$finalModel$W
      auprc <-roc_results[[6]]
      sensitivity <-roc_results[[4]]
      specificity <-roc_results[[5]]
      test_by_sample <-roc_results[[7]]
    }
    else{
      # We will use the permutation_importance function here to:
      #     1. Predict held-out test-data
      #     2. Calculate ROC and AUROC values on this prediction
      #     3. Get the feature importances for correlated and uncorrelated feautures
      roc_results <- permutation_importance(trained_model, test_data, first_outcome, second_outcome, outcome, level, test_samples, split_number)
      test_auc <- roc_results[[1]] # Predict the base test importance
      feature_importance_non_cor <- roc_results[2] # save permutation results of non-cor
      feature_importance_cor <- roc_results[3] # save permutation results of cor
      auprc <-roc_results[[6]]
      sensitivity <-roc_results[[4]]
      specificity <-roc_results[[5]]
      test_by_sample <-roc_results[[7]]
    }
  }else{
    print("No permutation test being performed.")
    if(model=="L1_Linear_SVM" || model=="L2_Linear_SVM" || model=="L2_Logistic_Regression"){
      # Get feature weights
      feature_importance_non_cor <- trained_model$finalModel$W
      # Get feature weights
      feature_importance_cor <- trained_model$finalModel$W
    }else{
      # Get feature weights
      feature_importance_non_cor <- NULL
      # Get feature weights
      feature_importance_cor <- NULL
    }
    # Calculate the test-auc for the actual pre-processed held-out data
    rpartProbs <- predict(trained_model, test_data, type="prob")
    test_roc <- roc(ifelse(test_data[,outcome] == first_outcome, 1, 0), rpartProbs[[1]])# if issue with null model (randomized outcome) add " , direction = '<' "
    test_auc <- test_roc$auc
    # Calculate the test auprc (area under precision-recall curve)
    bin_outcome <- get_binary_outcome(test_data[,outcome], first_outcome)
    auprc <- calc_auprc(rpartProbs[[1]], bin_outcome)
    # Calculate sensitivity and specificity for 0.5 decision threshold.
    p_class <- ifelse(rpartProbs[[1]] > 0.5, second_outcome, first_outcome)
    r <- confusionMatrix(as.factor(p_class), test_data[,outcome])
    sensitivity <- r$byClass[[1]]
    specificity <- r$byClass[[2]]
    test_by_sample <- test_samples %>% 
      select(Group, clearance) %>% 
      bind_cols(rpartProbs) %>% 
      mutate(seed = split_number,
        auroc = test_auc,
        auprc = auprc,
        sensitivity = sensitivity,
        specificity = specificity)
    
  }

  # ---------------------------------------------------------------------------------->

  # ----------------------------Save metrics as vector ------------------------------->
  # Return all the metrics
  results <- list(cv_auc, test_auc, results_individual, feature_importance_non_cor, feature_importance_cor, trained_model, sensitivity, specificity, auprc, test_by_sample)
  return(results)
}
