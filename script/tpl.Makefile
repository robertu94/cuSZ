#title           :tpl.Makefile
#description     :This snippet is used to generate Makefile.
#author          :Jiannan Tian
#copyright       :(C) 2021 by Washington State University, Argonne National Laboratory
#license         :See LICENSE in top-level directory
#date            :2021-01-10
#version         :0.2
#==============================================================================

#### presets
## --profile or -pg
##		Instrument generated code/executable for use by gprof (Linux only).
## --generate-line-info or -lineinfo
##		Generate line-number information for device code.
## --device-debug or -G
##		Generate debug information for device code. Turns off all optimizations.
##		Don't use for profiling; use -lineinfo instead.

#### compiler
CC       := g++ -std=c++14
NVCC     := nvcc -std=c++14
CC_FLAGS :=
NV_FLAGS := --expt-relaxed-constexpr --expt-extended-lambda

CUDA_VER      := $(shell nvcc --version | grep "release" | awk '{print $$5}' | cut -d, -f1)
# CUDA_VER_MAJ  := $(word 1, $(subst ., ,$(CUDA_VER)))
# CUDA_VER_MIN  := $(word 2, $(subst ., ,$(CUDA_VER)))
# CUDA_VER_STR  := $(CUDA_VER_MAJ)$(CUDA_VER_MIN)


#### external libs
NVCOMP_DIR        := external/nvcomp
NVCOMP_INCLUDE_DIR:= $(NVCOMP_DIR)/build/include
NVCOMP_LIB_DIR    := $(NVCOMP_DIR)/build/lib
NVCOMP_STATIC_LIB := $(NVCOMP_LIB_DIR)/libnvcomp.a

GTEST_DIR         := external/googletest
GTEST_INCLUDE_DIR := $(GTEST_DIR)/googletest/include
GTEST_LIB_DIR     := $(GTEST_DIR)/build/lib
GTEST_STATIC_LIB  := $(GTEST_LIB_DIR)/libgtest.a

libnvcomp: $(NVCOMP_STATIC_LIB)
libgtest:  $(GTEST_STATIC_LIB)

patch_nvcomp:
	patch external/nvcomp/src/CMakeLists.txt external/patch.nvcomp-1.1

$(NVCOMP_STATIC_LIB): patch_nvcomp
	cmake \
	    -DCUB_DIR=$(PWD)/external/cub \
	    -DCMAKE_C_COMPILER=$(shell which gcc) \
	    -DCMAKE_CXX_COMPILER=$(shell which g++) \
	    -S ${NVCOMP_DIR} -B ${NVCOMP_DIR}/build  && \
	make -j -C ${NVCOMP_DIR}/build

$(GTEST_STATIC_LIB):
	cmake \
	    -DCMAKE_C_COMPILER=$(shell which gcc) \
	    -DCMAKE_CXX_COMPILER=$(shell which g++) \
	    -S ${GTEST_DIR} -B ${GTEST_DIR}/build  && \
	make -j -C ${GTEST_DIR}/build

#### filesystem
SRC_DIR     := src
OBJ_DIR     := src
BIN_DIR     := bin

#### source code classification
CCsrc_omp :=$(SRC_DIR)/analysis_utils.cc
CCsrc     := $(filter-out $(CCsrc_omp), $(wildcard $(SRC_DIR)/*.cc))

MAIN      := $(SRC_DIR)/cusz.cu

CUsrc3    := $(SRC_DIR)/par_merge.cu $(SRC_DIR)/par_huffman.cu
CUsrc2    := $(SRC_DIR)/cusz_interface.cu $(SRC_DIR)/dualquant.cu
CUsrc1    := $(filter-out $(MAIN) $(CUsrc3) $(CUsrc2), $(wildcard $(SRC_DIR)/*.cu))

CCo_omp   := $(CCsrc_omp:$(SRC_DIR)/%.cc=$(OBJ_DIR)/%.o)
CCo       := $(CCsrc:$(SRC_DIR)/%.cc=$(OBJ_DIR)/%.o)

CUo1      := $(CUsrc1:$(SRC_DIR)/%.cu=$(OBJ_DIR)/%.o)
CUo2      := $(CUsrc2:$(SRC_DIR)/%.cu=$(OBJ_DIR)/%.o)
CUo3      := $(CUsrc3:$(SRC_DIR)/%.cu=$(OBJ_DIR)/%.o)

CUo       := $(CUo1) $(CUo2) $(CUo3)
OBJ_all   := $(CCo) $(CCo_omp) $(CUo)

$(CCo_omp): CC_FLAGS += -fopenmp
$(CUo2): NV_FLAGS += -rdc=true
$(CUo3): NV_FLAGS += -rdc=true

CC_FLAGS  += ####
NV_FLAGS  += ####
HW_TARGET += ####

$(info CUDA $(CUDA_VER) is in use.)

target_proxy: $(eval NV_FLAGS = $(NV_FLAGS) $(HW_TARGET))
target_proxy: ; @$(MAKE) cusz -j

#### compilation commands
all: target_proxy

#cusz: $(OBJ_all) | $(BIN_DIR)
#	$(NVCC) $(NV_FLAGS) -lgomp -lcusparse $(MAIN) -rdc=true $^ -o $(BIN_DIR)/$@

cusz: $(NVCOMP_STATIC_LIB) $(OBJ_all) $(GTEST_STATIC_LIB) | $(BIN_DIR)
	$(NVCC) $(NV_FLAGS) $(MAIN) \
		-lgomp -lcusparse -lpthread \
		-rdc=true \
		$(NVCOMP_STATIC_LIB) \
		$(GTEST_STATIC_LIB) -I$(GTEST_INCLUDE_DIR)/ \
		$^ -o $(BIN_DIR)/$@

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.cc libnvcomp | $(OBJ_DIR)
	$(CC) $(CC_FLAGS) -c $< -o $@

$(CUo): $(OBJ_DIR)/%.o: $(SRC_DIR)/%.cu libnvcomp | $(OBJ_DIR)
	$(NVCC) $(NV_FLAGS) -c $< -o $@

$(BIN_DIR):
	mkdir $@

install: bin/cusz
	cp bin/cusz /usr/local/bin

.PHONY: clean
clean:
	$(RM) $(OBJ_all)
