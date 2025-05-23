#pragma once 
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/system/cuda/execution_policy.h>
#include <thrust/logical.h>
#include <thrust/extrema.h>
#include <thrust/transform_reduce.h>
#include <thrust/functional.h>
#include "superlu_ddefs.h"
#include "lupanels_GPU.cuh"
// #include "lupanels.hpp"
#include "gpuCommon.hpp"
#include "cublas_cusolver_wrappers.hpp"

#define USABLE_GPU_MEM_FRACTION 0.9

size_t getGPUMemPerProcs(MPI_Comm baseCommunicator);

template <typename Ftype>
__global__ void indirectCopy(Ftype *dest, Ftype *src, int_t *idx, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n)
        dest[idx[i]] = src[i];
}

/**
 * @file schurCompUpdate.cu
 * @brief This function copies the packed buffers to GPU and performs the sparse
   initialization on GPU call indirectCopy, this is the kernel
 * @param gpuValBasePtr is the base pointer of the GPU matrix
 * @param valBufferPacked is the packed buffer of the matrix
 * @param valIdx is the index of the packed buffer
 */
 template <typename Ftype>
void copyToGPU(Ftype *gpuValBasePtr, std::vector<Ftype> &valBufferPacked,
               std::vector<int_t> &valIdx)
{
    int nnzCount = valBufferPacked.size();
    // calculate the size of the packed buffers
    int_t gpuLvalSizePacked = nnzCount * sizeof(Ftype);
    int_t gpuLidxSizePacked = nnzCount * sizeof(int_t);
    // allocate the memory for the packed buffers on GPU
    Ftype *dlvalPacked;
    int_t *dlidxPacked;
    gpuErrchk(cudaMalloc(&dlvalPacked, gpuLvalSizePacked));
    gpuErrchk(cudaMalloc(&dlidxPacked, gpuLidxSizePacked));
    // copy the packed buffers from CPU to GPU
    gpuErrchk(cudaMemcpy(dlvalPacked, valBufferPacked.data(), gpuLvalSizePacked, cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(dlidxPacked, valIdx.data(), gpuLidxSizePacked, cudaMemcpyHostToDevice));
    // perform the sparse initialization on GPU call indirectCopy
    const int ThreadblockSize = 256;
    int nThreadBlocks = (nnzCount + ThreadblockSize - 1) / ThreadblockSize;
    indirectCopy<<<nThreadBlocks, ThreadblockSize>>>(
        gpuValBasePtr, dlvalPacked, dlidxPacked, nnzCount);
    // wait for it to finish and free dlvalPacked and dlidxPacked
    gpuErrchk(cudaDeviceSynchronize());
    gpuErrchk(cudaFree(dlvalPacked));
    gpuErrchk(cudaFree(dlidxPacked));
}

// copy the panel to GPU
template <typename Ftype>
void copyToGPU_Sparse(Ftype *gpuValBasePtr, Ftype *valBuffer, int_t gpuLvalSize)
{
    // sparse Initialization for GPU, this is the experimental code
    // find non-zero elements in the panel, their location and values  and copy to GPU
    int numFtypes = gpuLvalSize / sizeof(Ftype);
    std::vector<Ftype> valBufferPacked;
    std::vector<int_t> valIdx;
    for (int_t i = 0; i < numFtypes; i++)
    {
        if (valBuffer[i] != 0)
        {
            valBufferPacked.push_back(valBuffer[i]);
            valIdx.push_back(i);
        }
    }
    printf("%d non-zero elements in the panel, wrt original=%d\n", valBufferPacked.size(), numFtypes);
    // get the size of the packed buffers and allocate memory on GPU
    copyToGPU(gpuValBasePtr, valBufferPacked, valIdx);
}

//#define NDEBUG
template <typename Ftype>
__device__ int_t xlpanelGPU_t<Ftype>::find(int_t k)
{
    int threadId = threadIdx.x;
    __shared__ int idx;
    __shared__ int found;
    if (!threadId)
    {
        idx = -1;
        found = 0;
    }

    int nThreads = blockDim.x;
    int blocksPerThreads = CEILING(nblocks(), nThreads);
    __syncthreads();
    for (int blk = blocksPerThreads * threadIdx.x;
         blk < blocksPerThreads * (threadIdx.x + 1);
         blk++)
    {
        if(found) break;

        if (blk < nblocks())
        {
            if (k == gid(blk))
            {
                idx = blk;
                found = 1;
            }
        }
    }
    __syncthreads();
    return idx;
}

template <typename Ftype>
__device__ int_t xupanelGPU_t<Ftype>::find(int_t k)
{
    int threadId = threadIdx.x;
    __shared__ int idx;
    __shared__ int found;
    if (!threadId)
    {
        idx = -1;
        found = 0;
    }
    __syncthreads();

    int nThreads = blockDim.x;
    int blocksPerThreads = CEILING(nblocks(), nThreads);

    for (int blk = blocksPerThreads * threadIdx.x;
         blk < blocksPerThreads * (threadIdx.x + 1);
         blk++)
    {
        if(found) break;

        if (blk < nblocks())
        {
            if (k == gid(blk))
            {
                idx = blk;
                found = 1;
            }
        }
    }
    __syncthreads();
    return idx;
}

__device__ int computeIndirectMapGPU(int *rcS2D, int_t srcLen, int_t *srcVec,
                                     int_t dstLen, int_t *dstVec,
                                     int *dstIdx)
{
    int threadId = threadIdx.x;
    if (dstVec == NULL) /*uncompressed dimension*/
    {
        if (threadId < srcLen)
            rcS2D[threadId] = srcVec[threadId];
        __syncthreads();
        return 0;
    }

    if (threadId < dstLen)
        dstIdx[dstVec[threadId]] = threadId;
    __syncthreads();

    if (threadId < srcLen)
        rcS2D[threadId] = dstIdx[srcVec[threadId]];
    __syncthreads();

    return 0;
}

template <typename Ftype>
__device__ void scatterGPU_dev(
    int iSt, int jSt,
    Ftype *gemmBuff, int LDgemmBuff,
    xlpanelGPU_t<Ftype>& lpanel, xupanelGPU_t<Ftype>& upanel,
    xLUstructGPU_t<Ftype> *dA
)
{
    // calculate gi,gj
    int ii = iSt + blockIdx.x;
    int jj = jSt + blockIdx.y;
    int threadId = threadIdx.x;

    int gi = lpanel.gid(ii);
    int gj = upanel.gid(jj);
#ifndef NDEBUG
    // if (!threadId)
    //     printf("Scattering to (%d, %d) \n", gi, gj);
#endif
    Ftype *Dst;
    int_t lddst;
    int_t dstRowLen, dstColLen;
    int_t *dstRowList;
    int_t *dstColList;
    int li, lj;
    if (gj > gi) // its in upanel
    {
        li = dA->g2lRow(gi);
        lj = dA->uPanelVec[li].find(gj);
        Dst = dA->uPanelVec[li].blkPtr(lj);
        lddst = dA->supersize(gi);
        dstRowLen = dA->supersize(gi);
        dstRowList = NULL;
        dstColLen = dA->uPanelVec[li].nbcol(lj);
        dstColList = dA->uPanelVec[li].colList(lj);
    }
    else
    {
        lj = dA->g2lCol(gj);
        li = dA->lPanelVec[lj].find(gi);
        Dst = dA->lPanelVec[lj].blkPtr(li);
        lddst = dA->lPanelVec[lj].LDA();
        dstRowLen = dA->lPanelVec[lj].nbrow(li);
        dstRowList = dA->lPanelVec[lj].rowList(li);
        // if(!threadId )
        // printf("Scattering to (%d, %d) by %d li=%d\n",gi, gj,threadId,li);
        dstColLen = dA->supersize(gj);
        dstColList = NULL;
    }

    // compute source row to dest row mapping
    int maxSuperSize = dA->maxSuperSize;
    extern __shared__ int baseSharedPtr[];
    int *rowS2D = baseSharedPtr;
    int *colS2D = &rowS2D[maxSuperSize];
    int *dstIdx = &colS2D[maxSuperSize];

    int nrows = lpanel.nbrow(ii);
    int ncols = upanel.nbcol(jj);
    // lpanel.rowList(ii), upanel.colList(jj)

    computeIndirectMapGPU(rowS2D, nrows, lpanel.rowList(ii),
                          dstRowLen, dstRowList, dstIdx);

    // compute source col to dest col mapping
    computeIndirectMapGPU(colS2D, ncols, upanel.colList(jj),
                          dstColLen, dstColList, dstIdx);

    int nThreads = blockDim.x;
    int colsPerThreadBlock = nThreads / nrows;

    int rowOff = lpanel.stRow(ii) - lpanel.stRow(iSt);
    int colOff = upanel.stCol(jj) - upanel.stCol(jSt);
    Ftype *Src = &gemmBuff[rowOff + colOff * LDgemmBuff];
    int ldsrc = LDgemmBuff;
    // TODO: this seems inefficient
    if (threadId < nrows * colsPerThreadBlock)
    {
        /* 1D threads are logically arranged in 2D shape. */
        int i = threadId % nrows;
        int j = threadId / nrows;

#pragma unroll 4
        while (j < ncols)
        {

#define ATOMIC_SCATTER
// Atomic Scatter is need if I want to perform multiple Schur Complement
//  update concurrently
#ifdef ATOMIC_SCATTER
            atomicAddT<Ftype>(&Dst[rowS2D[i] + lddst * colS2D[j]], -Src[i + ldsrc * j]);
#else
            Dst[rowS2D[i] + lddst * colS2D[j]] -= Src[i + ldsrc * j];
#endif
            j += colsPerThreadBlock;
        }
    }

    __syncthreads();
}
template <typename Ftype>
__global__ void scatterGPU(
    int iSt, int jSt,
    Ftype *gemmBuff, int LDgemmBuff,
    xlpanelGPU_t<Ftype> lpanel, xupanelGPU_t<Ftype> upanel,
    xLUstructGPU_t<Ftype> *dA)
{
    scatterGPU_dev(iSt, jSt, gemmBuff, LDgemmBuff, lpanel, upanel, dA);
}

template <typename Ftype>
__global__ void scatterGPU_batch(
    int* iSt_batch, int *iEnd_batch, int *jSt_batch, int *jEnd_batch, 
    Ftype **gemmBuff_ptrs, int *LDgemmBuff_batch, xlpanelGPU_t<Ftype> *lpanels, 
    xupanelGPU_t<Ftype> *upanels, xLUstructGPU_t<Ftype> *dA
)
{
    int batch_index = blockIdx.z;
    int iSt = iSt_batch[batch_index], iEnd = iEnd_batch[batch_index];
    int jSt = jSt_batch[batch_index], jEnd = jEnd_batch[batch_index];
    
    int ii = iSt + blockIdx.x;
    int jj = jSt + blockIdx.y;
    if(ii >= iEnd || jj >= jEnd)
        return;
    
    Ftype* gemmBuff = gemmBuff_ptrs[batch_index];
    if(gemmBuff == NULL)
        return;

    int LDgemmBuff = LDgemmBuff_batch[batch_index];
    lpanelGPU_t& lpanel = lpanels[batch_index];
    upanelGPU_t& upanel = upanels[batch_index];
    scatterGPU_dev(iSt, jSt, gemmBuff, LDgemmBuff, lpanel, upanel, dA);
}

template <typename Ftype>
void scatterGPU_driver(
    int iSt, int iEnd, int jSt, int jEnd, Ftype *gemmBuff, int LDgemmBuff,
    int maxSuperSize, int ldt, xlpanelGPU_t<Ftype> lpanel, xupanelGPU_t<Ftype> upanel, 
    xLUstructGPU_t<Ftype> *dA, cudaStream_t cuStream
)
{
    dim3 dimBlock(ldt); // 1d thread
    dim3 dimGrid(iEnd - iSt, jEnd - jSt);
    size_t sharedMemorySize = 3 * maxSuperSize * sizeof(int_t);

    scatterGPU<Ftype><<<dimGrid, dimBlock, sharedMemorySize, cuStream>>>(
        iSt, jSt, gemmBuff, LDgemmBuff, lpanel, upanel, dA
    );

    gpuErrchk(cudaGetLastError());
}

template <typename Ftype>
void scatterGPU_batchDriver(
    int* iSt_batch, int *iEnd_batch, int *jSt_batch, int *jEnd_batch, 
    int max_ilen, int max_jlen, Ftype **gemmBuff_ptrs, int *LDgemmBuff_batch, 
    int maxSuperSize, int ldt, xlpanelGPU_t<Ftype> *lpanels, xupanelGPU_t<Ftype> *upanels, 
    xLUstructGPU_t<Ftype> *dA, int batchCount, cudaStream_t cuStream
)
{
    const int op_increment = 65535;
    
    for(int op_start = 0; op_start < batchCount; op_start += op_increment)
	{
		int batch_size = std::min(op_increment, batchCount - op_start);
    
        dim3 dimBlock(ldt); // 1d thread
        dim3 dimGrid(max_ilen, max_jlen, batch_size);
        size_t sharedMemorySize = 3 * maxSuperSize * sizeof(int_t);

        scatterGPU_batch<Ftype><<<dimGrid, dimBlock, sharedMemorySize, cuStream>>>(
            iSt_batch + op_start, iEnd_batch + op_start, jSt_batch + op_start, 
            jEnd_batch + op_start, gemmBuff_ptrs + op_start, LDgemmBuff_batch + op_start, 
            lpanels + op_start, upanels + op_start, dA 
        );
    }
}

template <typename Ftype>
int_t xLUstruct_t<Ftype>::dSchurComplementUpdateGPU(
    int streamId,
    int_t k, // the k-th panel or supernode
    xlpanel_t<Ftype> &lpanel, xupanel_t<Ftype> &upanel)
{

    if (lpanel.isEmpty() || upanel.isEmpty())
        return 0;

    int_t st_lb = 0;
    if (myrow == krow(k))
        st_lb = 1;

    int_t nlb = lpanel.nblocks();
    int_t nub = upanel.nblocks();

    int iSt = st_lb;
    int iEnd = iSt;

    int nrows = lpanel.stRow(nlb) - lpanel.stRow(st_lb);
    int ncols = upanel.nzcols();

    int maxGemmRows = nrows;
    int maxGemmCols = ncols;
    // entire gemm doesn't fit in gemm buffer
    if (nrows * ncols > A_gpu.gemmBufferSize)
    {
        int maxGemmOpSize = (int)sqrt(A_gpu.gemmBufferSize);
        int numberofRowChunks = (nrows + maxGemmOpSize - 1) / maxGemmOpSize;
        maxGemmRows = nrows / numberofRowChunks;
        maxGemmCols = A_gpu.gemmBufferSize / maxGemmRows;
        /* printf("buffer exceeded! k = %d, st_lb = %d, nlb = %d, nrowsXncols %d, maxGemRows %d, maxGemmCols %d\n",
	   k, st_lb, nlb, nrows*ncols, maxGemmRows, maxGemmCols);*/
    }

    while (iEnd < nlb)
    {
        iSt = iEnd;
        iEnd = lpanel.getEndBlock(iSt, maxGemmRows);
        
        assert(iEnd > iSt);
        int jSt = 0;
        int jEnd = 0;
        while (jEnd < nub)
        {
            jSt = jEnd;
            jEnd = upanel.getEndBlock(jSt, maxGemmCols);
            assert(jEnd > jSt);
            cublasHandle_t handle = A_gpu.cuHandles[streamId];
            cudaStream_t cuStream = A_gpu.cuStreams[streamId];
            cublasSetStream(handle, cuStream);
            int gemm_m = lpanel.stRow(iEnd) - lpanel.stRow(iSt);
            int gemm_n = upanel.stCol(jEnd) - upanel.stCol(jSt);
            int gemm_k = supersize(k);
#if 0           
            printf("k = %d, iSt = %d, iEnd = %d, jst = %d, jend = %d\n", k, iSt, iEnd, jSt, jEnd);
            printf("m=%d, n=%d, k=%d\n", gemm_m, gemm_n, gemm_k);
	    fflush(stdout);
#endif	    

            Ftype alpha = one<Ftype>();
            Ftype beta = zeroT<Ftype>();
            // cublasDgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N,
            //             gemm_m, gemm_n, gemm_k, &alpha,
            //             lpanel.blkPtrGPU(iSt), lpanel.LDA(),
            //             upanel.blkPtrGPU(jSt), upanel.LDA(), &beta,
            //             A_gpu.gpuGemmBuffs[streamId], gemm_m);
            myCublasGemm<Ftype>(handle, CUBLAS_OP_N, CUBLAS_OP_N,
                                gemm_m, gemm_n, gemm_k, &alpha,
                                lpanel.blkPtrGPU(iSt), lpanel.LDA(),
                                upanel.blkPtrGPU(jSt), upanel.LDA(), &beta,
                                A_gpu.gpuGemmBuffs[streamId], gemm_m);
	    stat->ops[FACT] += 2 * gemm_m * gemm_n * gemm_k;

            scatterGPU_driver<Ftype>(
                iSt, iEnd, jSt, jEnd, A_gpu.gpuGemmBuffs[streamId], gemm_m,
                A_gpu.maxSuperSize, ldt, lpanel.gpuPanel, upanel.gpuPanel, 
                dA_gpu, cuStream
            );
    	    stat->ops[FACT] += gemm_m * gemm_n; // scatter

        }
    }
    gpuErrchk(cudaStreamSynchronize(A_gpu.cuStreams[streamId]));
    return 0;
} /* end dSchurComplementUpdateGPU */

template <typename Ftype>
int_t xLUstruct_t<Ftype>::lookAheadUpdateGPU(
    int streamId,
    int_t k, int_t laIdx, xlpanel_t<Ftype> &lpanel, xupanel_t<Ftype> &upanel)
{
    if (lpanel.isEmpty() || upanel.isEmpty())
        return 0;

    int_t st_lb = 0;
    if (myrow == krow(k))
        st_lb = 1;

    int_t nlb = lpanel.nblocks();
    int_t nub = upanel.nblocks();

    int_t laILoc = lpanel.find(laIdx);
    int_t laJLoc = upanel.find(laIdx);

    int iSt = st_lb;
    int jSt = 0;

    /* call look ahead update on Lpanel*/
    if (laJLoc != GLOBAL_BLOCK_NOT_FOUND)
        dSchurCompUpdatePartGPU(
            iSt, nlb, laJLoc, laJLoc + 1,
            k, lpanel, upanel,
            A_gpu.lookAheadLHandle[streamId], A_gpu.lookAheadLStream[streamId],
            A_gpu.lookAheadLGemmBuffer[streamId]);

    /* call look ahead update on Upanel*/
    if (laILoc != GLOBAL_BLOCK_NOT_FOUND)
    {
        dSchurCompUpdatePartGPU(
            laILoc, laILoc + 1, jSt, laJLoc,
            k, lpanel, upanel,
            A_gpu.lookAheadUHandle[streamId], A_gpu.lookAheadUStream[streamId],
            A_gpu.lookAheadUGemmBuffer[streamId]);
        dSchurCompUpdatePartGPU(
            laILoc, laILoc + 1, laJLoc + 1, nub,
            k, lpanel, upanel,
            A_gpu.lookAheadUHandle[streamId], A_gpu.lookAheadUStream[streamId],
            A_gpu.lookAheadUGemmBuffer[streamId]);
    }

    // checkCudaLocal(cudaStreamSynchronize(A_gpu.lookAheadLStream[streamId]));
    // checkCudaLocal(cudaStreamSynchronize(A_gpu.lookAheadUStream[streamId]));

    return 0;
}

template <typename Ftype>
int_t xLUstruct_t<Ftype>::SyncLookAheadUpdate(int streamId)
{
    gpuErrchk(cudaStreamSynchronize(A_gpu.lookAheadLStream[streamId]));
    gpuErrchk(cudaStreamSynchronize(A_gpu.lookAheadUStream[streamId]));

    return 0;
}

template <typename Ftype>
int_t xLUstruct_t<Ftype>::dSchurCompUpdateExcludeOneGPU(
    int streamId,
    int_t k, int_t ex, // suypernodes to be excluded
    xlpanel_t<Ftype> &lpanel, xupanel_t<Ftype> &upanel)
{
    if (lpanel.isEmpty() || upanel.isEmpty())
        return 0;

    int_t st_lb = 0;
    if (myrow == krow(k))
        st_lb = 1;

    int_t nlb = lpanel.nblocks();
    int_t nub = upanel.nblocks();

    int_t exILoc = lpanel.find(ex);
    int_t exJLoc = upanel.find(ex);

    dSchurCompUpLimitedMem(
        streamId,
        st_lb, exILoc, 0, exJLoc,
        k, lpanel, upanel);

    dSchurCompUpLimitedMem(
        streamId,
        st_lb, exILoc, exJLoc + 1, nub,
        k, lpanel, upanel);

    int_t nextStI = exILoc + 1;
    if (exILoc == GLOBAL_BLOCK_NOT_FOUND)
        nextStI = st_lb;
    /*
    for j we don't need to change since, if exJLoc == GLOBAL_BLOCK_NOT_FOUND =-1
    then exJLoc+1 =0 will work out correctly as starting j
    */
    dSchurCompUpLimitedMem(
        streamId,
        nextStI, nlb, 0, exJLoc,
        k, lpanel, upanel);

    dSchurCompUpLimitedMem(
        streamId,
        nextStI, nlb, exJLoc + 1, nub,
        k, lpanel, upanel);

    // checkCudaLocal(cudaStreamSynchronize(A_gpu.cuStreams[streamId]));
    return 0;
}

template <typename Ftype>
int_t xLUstruct_t<Ftype>::dSchurCompUpdatePartGPU(
    int_t iSt, int_t iEnd, int_t jSt, int_t jEnd,
    int_t k, xlpanel_t<Ftype> &lpanel, xupanel_t<Ftype> &upanel,
    cublasHandle_t handle, cudaStream_t cuStream,
    Ftype *gemmBuff)
{
    if (iSt >= iEnd || jSt >= jEnd)
        return 0;

    cublasSetStream(handle, cuStream);
    int gemm_m = lpanel.stRow(iEnd) - lpanel.stRow(iSt);
    int gemm_n = upanel.stCol(jEnd) - upanel.stCol(jSt);
    int gemm_k = supersize(k);
    Ftype alpha = one<Ftype>();
    Ftype beta = zeroT<Ftype>();
#ifndef NDEBUG
   // printf("m=%d, n=%d, k=%d\n", gemm_m, gemm_n, gemm_k);
#endif
    // cublasDgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N,
    //             gemm_m, gemm_n, gemm_k, &alpha,
    //             lpanel.blkPtrGPU(iSt), lpanel.LDA(),
    //             upanel.blkPtrGPU(jSt), upanel.LDA(), &beta,
    //             gemmBuff, gemm_m);

    myCublasGemm<Ftype>(handle, CUBLAS_OP_N, CUBLAS_OP_N,
                        gemm_m, gemm_n, gemm_k, &alpha,
                        lpanel.blkPtrGPU(iSt), lpanel.LDA(),
                        upanel.blkPtrGPU(jSt), upanel.LDA(), &beta,
                        gemmBuff, gemm_m);

    stat->ops[FACT] += 2 * gemm_m * gemm_n * gemm_k;

    // setting up scatter
    dim3 dimBlock(ldt); // 1d thread
    dim3 dimGrid(iEnd - iSt, jEnd - jSt);
    size_t sharedMemorySize = 3 * A_gpu.maxSuperSize * sizeof(int_t);

    scatterGPU<Ftype><<<dimGrid, dimBlock, sharedMemorySize, cuStream>>>(
        iSt, jSt,
        gemmBuff, gemm_m,
        lpanel.gpuPanel, upanel.gpuPanel, dA_gpu);

    stat->ops[FACT] += gemm_m * gemm_n; // scatter
    
    return 0;
} /* end dSchurCompUpdatePartGPU() */

template <typename Ftype>
int_t xLUstruct_t<Ftype>::dSchurCompUpLimitedMem(
    int streamId,
    int_t lStart, int_t lEnd,
    int_t uStart, int_t uEnd,
    int_t k, xlpanel_t<Ftype> &lpanel, xupanel_t<Ftype> &upanel)
{

    if (lStart >= lEnd || uStart >= uEnd)
        return 0;
    int iSt = lStart;
    int iEnd = iSt;
    int nrows = lpanel.stRow(lEnd) - lpanel.stRow(lStart);
    int ncols = upanel.stCol(uEnd) - upanel.stCol(uStart);

    int maxGemmRows = nrows;
    int maxGemmCols = ncols;
    // entire gemm doesn't fit in gemm buffer
    if (nrows * ncols > A_gpu.gemmBufferSize)
    {
        int maxGemmOpSize = (int)sqrt(A_gpu.gemmBufferSize);
        int numberofRowChunks = (nrows + maxGemmOpSize - 1) / maxGemmOpSize;
        maxGemmRows = nrows / numberofRowChunks;
        maxGemmCols = A_gpu.gemmBufferSize / maxGemmRows;
    }

    while (iEnd < lEnd)
    {
        iSt = iEnd;
        iEnd = lpanel.getEndBlock(iSt, maxGemmRows);
        if (iEnd > lEnd)
            iEnd = lEnd;

        assert(iEnd > iSt);
        int jSt = uStart;
        int jEnd = uStart;
        while (jEnd < uEnd)
        {
            jSt = jEnd;
            jEnd = upanel.getEndBlock(jSt, maxGemmCols);
            if (jEnd > uEnd)
                jEnd = uEnd;

            cublasHandle_t handle = A_gpu.cuHandles[streamId];
            cudaStream_t cuStream = A_gpu.cuStreams[streamId];
            dSchurCompUpdatePartGPU(iSt, iEnd, jSt, jEnd,
                                    k, lpanel, upanel, handle, cuStream, A_gpu.gpuGemmBuffs[streamId]);
        }
    }

    return 0;
}

int getMPIProcsPerGPU()
{
    if (!(getenv("MPI_PROCESS_PER_GPU")))
    {
        return 1;
    } else {
        int devCount;
        cudaGetDeviceCount(&devCount);
        int envCount = atoi(getenv("MPI_PROCESS_PER_GPU"));
        envCount = SUPERLU_MAX(envCount, 1);
        printf("MPI_PROCESS_PER_GPU=%d, devCount=%d\n", envCount, devCount);
        return SUPERLU_MIN(envCount, devCount);
    }
}

// #define USABLE_GPU_MEM_FRACTION 0.9

size_t getGPUMemPerProcs(MPI_Comm baseCommunicator)
{
    size_t mfree, mtotal;
    // TODO: shared memory communicator should be part of
    //  LU struct
    //  MPI_Comm sharedComm;
    //  MPI_Comm_split_type(baseCommunicator, MPI_COMM_TYPE_SHARED,
    //                      0, MPI_INFO_NULL, &sharedComm);
    //  MPI_Barrier(sharedComm);
    cudaMemGetInfo(&mfree, &mtotal);
    // MPI_Barrier(sharedComm);
    // MPI_Comm_free(&sharedComm);
#if 0
    printf("Total memory %zu & free memory %zu\n", mtotal, mfree);
#endif
    //return (size_t)(USABLE_GPU_MEM_FRACTION * (Ftype)mfree) / getMPIProcsPerGPU();
    return (size_t)(USABLE_GPU_MEM_FRACTION * (double)mfree) / getMPIProcsPerGPU();
}

template <typename Ftype>
int_t xLUstruct_t<Ftype>::setLUstruct_GPU()
{
    int i, stream;
    
#if (DEBUGlevel >= 1)
    int iam = 0;
    CHECK_MALLOC(iam, "Enter setLUstruct_GPU()"); fflush(stdout);
#endif
	
    A_gpu.Pr = Pr;
    A_gpu.Pc = Pc;
    A_gpu.maxSuperSize = ldt;

    /* Sherry: this mapping may be inefficient on Frontier. Yang: I commented it out as the mapping can be set by env SUPERLU_BIND_MPI_GPU in superlu_gridinit3d */
    /*Mapping to device*/
    // int deviceCount;
    // cudaGetDeviceCount(&deviceCount); // How many GPUs?
    // int device_id = grid3d->iam % deviceCount;
    // cudaSetDevice(device_id);

    double tRegion[5];
    size_t useableGPUMem = getGPUMemPerProcs(grid3d->comm);
    /**
     *  Memory is divided into two parts data memory and buffer memory
     *  data memory is used for useful data
     *  bufferMemory is used for buffers
     * */
    size_t memReqData = 0;

    /*Memory for XSUP*/
    memReqData += (nsupers + 1) * sizeof(int_t);

    tRegion[0] = SuperLU_timer_();
    
    size_t totalNzvalSize = 0; /* too big for gemmBufferSize */
    size_t max_gemmCsize = 0;  /* Sherry added 2/20/2023 */
    size_t max_nzrow = 0;  /* Yang added 10/20/2023 */
    size_t max_nzcol = 0;  
    
    /*Memory for lpapenl and upanel Data*/
    for (i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
        {
            memReqData += lPanelVec[i].totalSize();
            totalNzvalSize += lPanelVec[i].nzvalSize();
            if(lPanelVec[i].nzvalSize()>0)
                max_nzrow = SUPERLU_MAX(lPanelVec[i].nzrows(),max_nzrow);
	    //max_gemmCsize = SUPERoLU_MAX(max_gemmCsize, ???);
        }
    }
    for (i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
        {
            memReqData += uPanelVec[i].totalSize();
            totalNzvalSize += uPanelVec[i].nzvalSize();
            if(uPanelVec[i].nzvalSize()>0)
                max_nzcol = SUPERLU_MAX(uPanelVec[i].nzcols(),max_nzcol);
        }
    }
    max_gemmCsize = max_nzcol*max_nzrow;
    
    memReqData += CEILING(nsupers, Pc) * sizeof(lpanelGPU_t);
    memReqData += CEILING(nsupers, Pr) * sizeof(upanelGPU_t);

    memReqData += sizeof(xLUstructGPU_t<Ftype>);
    
    // Per stream data
    // TODO: estimate based on ancestor size
    int_t maxBuffSize = sp_ienv_dist (8, options);
    int maxsup = sp_ienv_dist(3, options); // max. supernode size
    maxBuffSize = SUPERLU_MAX(maxsup * maxsup, maxBuffSize); // Sherry added 7/10/23
    
 #if 0   
    A_gpu.gemmBufferSize = SUPERLU_MIN(maxBuffSize, totalNzvalSize); 
 #else 
    A_gpu.gemmBufferSize = SUPERLU_MIN(maxBuffSize, SUPERLU_MAX(max_gemmCsize,totalNzvalSize)); /* Yang added 10/20/2023 */
 #endif
 
    size_t dataPerStream = 3 * sizeof(Ftype) * maxLvalCount + 3 * sizeof(Ftype) * maxUvalCount + 2 * sizeof(int_t) * maxLidxCount + 2 * sizeof(int_t) * maxUidxCount + A_gpu.gemmBufferSize * sizeof(Ftype) + ldt * ldt * sizeof(Ftype);
    if (memReqData + 2 * dataPerStream > useableGPUMem)
    {
        printf("Not enough memory on GPU: available = %zu, required for 2 streams =%zu, exiting\n", useableGPUMem, memReqData + 2 * dataPerStream);
        exit(-1);
    }

    tRegion[0] = SuperLU_timer_() - tRegion[0];
#if ( PRNTlevel>=1 )    
    // print the time taken to estimate memory on GPU
    if (grid3d->iam == 0)
    {
        // printf("GPU deviceCount=%d\n", deviceCount);
	printf("\t.. totalNzvalSize %ld, gemmBufferSize %ld\n",
	       (long) totalNzvalSize, (long) A_gpu.gemmBufferSize);
    }
#endif

    /*Memory for lapenlPanel Data*/
    tRegion[1] = SuperLU_timer_();

    int_t maxNumberOfStream = (useableGPUMem - memReqData) / dataPerStream;

    int numberOfStreams = SUPERLU_MIN(getNumLookAhead(options), maxNumberOfStream);
    numberOfStreams = SUPERLU_MIN(numberOfStreams, MAX_CUDA_STREAMS);
    int rNumberOfStreams;
    MPI_Allreduce(&numberOfStreams, &rNumberOfStreams, 1,
                  MPI_INT, MPI_MIN, grid3d->comm);
    A_gpu.numCudaStreams = rNumberOfStreams;

#if ( PRNTlevel>=1 )    
    if (!grid3d->iam)
        printf("Using %d CUDA LookAhead streams\n", rNumberOfStreams);
    // size_t totalMemoryRequired = memReqData + numberOfStreams * dataPerStream;
#endif    

#if 0 /**** Old code ****/
    upanelGPU_t *uPanelVec_GPU = new upanelGPU_t[CEILING(nsupers, Pr)];
    lpanelGPU_t *lPanelVec_GPU = new lpanelGPU_t[CEILING(nsupers, Pc)];
    void *gpuBasePtr, *gpuCurrentPtr;
    cudaMalloc(&gpuBasePtr, totalMemoryRequired);
    gpuCurrentPtr = gpuBasePtr;

    A_gpu.xsup = (int_t *)gpuCurrentPtr;
    gpuCurrentPtr = (int_t *)gpuCurrentPtr + (nsupers + 1);
    cudaMemcpy(A_gpu.xsup, xsup, (nsupers + 1) * sizeof(int_t), cudaMemcpyHostToDevice);

    for (int i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
        {
            lPanelVec_GPU[i] = lPanelVec[i].copyToGPU(gpuCurrentPtr);
            gpuCurrentPtr = (char *)gpuCurrentPtr + lPanelVec[i].totalSize();
        }
    }
    A_gpu.lPanelVec = (xlpanelGPU_t<Ftype> *)gpuCurrentPtr;
    gpuCurrentPtr = (char *)gpuCurrentPtr + CEILING(nsupers, Pc) * sizeof(xlpanelGPU_t<Ftype>);
    cudaMemcpy(A_gpu.lPanelVec, lPanelVec_GPU,
               CEILING(nsupers, Pc) * sizeof(xlpanelGPU_t<Ftype>), cudaMemcpyHostToDevice);

    for (int i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
        {
            uPanelVec_GPU[i] = uPanelVec[i].copyToGPU(gpuCurrentPtr);
            gpuCurrentPtr = (char *)gpuCurrentPtr + uPanelVec[i].totalSize();
        }
    }
    A_gpu.uPanelVec = (xupanelGPU_t<Ftype> *)gpuCurrentPtr;
    gpuCurrentPtr = (char *)gpuCurrentPtr + CEILING(nsupers, Pr) * sizeof(xupanelGPU_t<Ftype>);
    cudaMemcpy(A_gpu.uPanelVec, uPanelVec_GPU,
               CEILING(nsupers, Pr) * sizeof(xupanelGPU_t<Ftype>), cudaMemcpyHostToDevice);

    for (int stream = 0; stream < A_gpu.numCudaStreams; stream++)
    {

        cudaStreamCreate(&A_gpu.cuStreams[stream]);
        cublasCreate(&A_gpu.cuHandles[stream]);
        A_gpu.LvalRecvBufs[stream] = (Ftype *)gpuCurrentPtr;
        gpuCurrentPtr = (Ftype *)gpuCurrentPtr + maxLvalCount;
        A_gpu.UvalRecvBufs[stream] = (Ftype *)gpuCurrentPtr;
        gpuCurrentPtr = (Ftype *)gpuCurrentPtr + maxUvalCount;
        A_gpu.LidxRecvBufs[stream] = (int_t *)gpuCurrentPtr;
        gpuCurrentPtr = (int_t *)gpuCurrentPtr + maxLidxCount;
        A_gpu.UidxRecvBufs[stream] = (int_t *)gpuCurrentPtr;
        gpuCurrentPtr = (int_t *)gpuCurrentPtr + maxUidxCount;

        A_gpu.gpuGemmBuffs[stream] = (Ftype *)gpuCurrentPtr;
        gpuCurrentPtr = (Ftype *)gpuCurrentPtr + A_gpu.gemmBufferSize;
        A_gpu.dFBufs[stream] = (Ftype *)gpuCurrentPtr;
        gpuCurrentPtr = (Ftype *)gpuCurrentPtr + ldt * ldt;

        /*lookAhead buffers and stream*/
        cublasCreate(&A_gpu.lookAheadLHandle[stream]);
        cudaStreamCreate(&A_gpu.lookAheadLStream[stream]);
        A_gpu.lookAheadLGemmBuffer[stream] = (Ftype *)gpuCurrentPtr;
        gpuCurrentPtr = (Ftype *)gpuCurrentPtr + maxLvalCount;
        cublasCreate(&A_gpu.lookAheadUHandle[stream]);
        cudaStreamCreate(&A_gpu.lookAheadUStream[stream]);
        A_gpu.lookAheadUGemmBuffer[stream] = (Ftype *)gpuCurrentPtr;
        gpuCurrentPtr = (Ftype *)gpuCurrentPtr + maxUvalCount;
    }
    // cudaCheckError();
    // allocate
    dA_gpu = (xLUstructGPU_t<Ftype> *)gpuCurrentPtr;

    cudaMemcpy(dA_gpu, &A_gpu, sizeof(xLUstructGPU_t<Ftype>), cudaMemcpyHostToDevice);
    gpuCurrentPtr = (xLUstructGPU_t<Ftype> *)gpuCurrentPtr + 1;

#else /* else of #if 0 ----> this is the current active code - Sherry */
    gpuErrchk(cudaMalloc(&A_gpu.xsup, (nsupers + 1) * sizeof(int_t)));
    gpuErrchk(cudaMemcpy(A_gpu.xsup, xsup, (nsupers + 1) * sizeof(int_t), cudaMemcpyHostToDevice));

    double tLsend, tUsend;
#if 0
    tLsend = SuperLU_timer_();
    xupanelGPU_t<Ftype> *uPanelVec_GPU = copyUpanelsToGPU();
    tLsend = SuperLU_timer_() - tLsend;
    tUsend = SuperLU_timer_();
    xlpanelGPU_t<Ftype> *lPanelVec_GPU = copyLpanelsToGPU();
    tUsend = SuperLU_timer_() - tUsend;
#else 
    uPanelVec_GPU = new xupanelGPU_t<Ftype>[CEILING(nsupers, Pr)];
    lPanelVec_GPU = new xlpanelGPU_t<Ftype>[CEILING(nsupers, Pc)];
    tLsend = SuperLU_timer_();
    for (i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
            lPanelVec_GPU[i] = lPanelVec[i].copyToGPU();
    }
    tLsend = SuperLU_timer_() - tLsend;
    tUsend = SuperLU_timer_();
    // cudaCheckError();
    for (i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            uPanelVec_GPU[i] = uPanelVec[i].copyToGPU();
    }
    tUsend = SuperLU_timer_() - tUsend;
#endif
    tRegion[1] = SuperLU_timer_() - tRegion[1];

    gpuErrchk(cudaMalloc(&A_gpu.lPanelVec, CEILING(nsupers, Pc) * sizeof(xlpanelGPU_t<Ftype>)));
    gpuErrchk(cudaMemcpy(A_gpu.lPanelVec, lPanelVec_GPU,
               CEILING(nsupers, Pc) * sizeof(xlpanelGPU_t<Ftype>), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMalloc(&A_gpu.uPanelVec, CEILING(nsupers, Pr) * sizeof(xupanelGPU_t<Ftype>)));
    gpuErrchk(cudaMemcpy(A_gpu.uPanelVec, uPanelVec_GPU,
               CEILING(nsupers, Pr) * sizeof(xupanelGPU_t<Ftype>), cudaMemcpyHostToDevice));

    // delete [] uPanelVec_GPU;
    // delete [] lPanelVec_GPU;

    tRegion[2] = SuperLU_timer_();
    int dfactBufSize = 0;
    // TODO: does it work with NULL pointer?
    cusolverDnHandle_t cusolverH = NULL;
    cusolverDnCreate(&cusolverH);
    
    cusolverDnDgetrf_bufferSize(cusolverH, ldt, ldt, NULL, ldt, &dfactBufSize);
    
    cusolverDnDestroy(cusolverH);
#if ( PRNTlevel >= 1 )    
    printf("Size of dfactBuf is %d\n", dfactBufSize);
#endif    
    tRegion[2] = SuperLU_timer_() - tRegion[2];
    
    tRegion[3] = SuperLU_timer_();

    double tcuMalloc=SuperLU_timer_();

    /* Sherry: where are these freed ?? */
    for (stream = 0; stream < A_gpu.numCudaStreams; stream++)
    {
        gpuErrchk(cudaMalloc(&A_gpu.LvalRecvBufs[stream], sizeof(Ftype) * maxLvalCount));
        gpuErrchk(cudaMalloc(&A_gpu.UvalRecvBufs[stream], sizeof(Ftype) * maxUvalCount));
        gpuErrchk(cudaMalloc(&A_gpu.LidxRecvBufs[stream], sizeof(int_t) * maxLidxCount));
        gpuErrchk(cudaMalloc(&A_gpu.UidxRecvBufs[stream], sizeof(int_t) * maxUidxCount));
        // allocate the space for diagonal factor on GPU
        gpuErrchk(cudaMalloc(&A_gpu.diagFactWork[stream], sizeof(Ftype) * dfactBufSize));
        gpuErrchk(cudaMalloc(&A_gpu.diagFactInfo[stream], sizeof(int)));

        /*lookAhead buffers and stream*/
        gpuErrchk(cudaMalloc(&A_gpu.lookAheadLGemmBuffer[stream], sizeof(Ftype) * maxLvalCount));

        gpuErrchk(cudaMalloc(&A_gpu.lookAheadUGemmBuffer[stream], sizeof(Ftype) * maxUvalCount));
	// Sherry: replace this by new code 
        //cudaMalloc(&A_gpu.dFBufs[stream], ldt * ldt * sizeof(Ftype));
        //cudaMalloc(&A_gpu.gpuGemmBuffs[stream], A_gpu.gemmBufferSize * sizeof(Ftype));
    }
    
    /* Sherry: dfBufs[] changed to Ftype pointer **, max(batch, numCudaStreams) */
    int mxLeafNode = trf3Dpartition->mxLeafNode, mx_fsize = 0;

    /* Compute gemmCsize[] for batch operations 
       !!!!!!! WARNING: this only works for 1 MPI  !!!!!! */
    if ( options->batchCount > 0 ) {
	trf3Dpartition->gemmCsizes = int32Calloc_dist(mxLeafNode);
	int k, k0, k_st, k_end, offset, Csize;
	
	for (int ilvl = 0; ilvl < maxLvl; ++ilvl) {  /* Loop through the Pz tree levels */
	    int treeId = trf3Dpartition->myTreeIdxs[ilvl];
	    sForest_t* sforest = trf3Dpartition->sForests[treeId];
	    if (sforest){
		int_t *perm_c_supno = sforest->nodeList ;
        mx_fsize = max((int_t)mx_fsize, sforest->nNodes);

		int maxTopoLevel = sforest->topoInfo.numLvl;/* number of levels at each outer-tree node */
		for (int topoLvl = 0; topoLvl < maxTopoLevel; ++topoLvl) {
		    k_st = sforest->topoInfo.eTreeTopLims[topoLvl];
		    k_end = sforest->topoInfo.eTreeTopLims[topoLvl + 1];
		
		    for (k0 = k_st; k0 < k_end; ++k0) {
			offset = k0 - k_st;
			k = perm_c_supno[k0];
			Csize = lPanelVec[k].nzrows() * uPanelVec[k].nzcols();
			trf3Dpartition->gemmCsizes[offset] =
			    SUPERLU_MAX(trf3Dpartition->gemmCsizes[offset], Csize);
		    }
		}
	    }
	}
    }
    
    int num_dfbufs;  /* number of diagonal buffers */
    num_dfbufs = A_gpu.numCudaStreams;
    int num_gemmbufs = num_dfbufs;
#if ( PRNTlevel >= 1 )    
    printf(".. setLUstrut_GPU: num_dfbufs %d, num_gemmbufs %d\n", num_dfbufs, num_gemmbufs);
    fflush(stdout);
#endif

    A_gpu.dFBufs = (Ftype **) SUPERLU_MALLOC(num_dfbufs * sizeof(Ftype *));
    A_gpu.gpuGemmBuffs = (Ftype **) SUPERLU_MALLOC(num_gemmbufs * sizeof(Ftype *));
    
    int l, sum_diag_size = 0, sum_gemmC_size = 0;
    
	l = ldt * ldt;
	for (i = 0; i < num_dfbufs; ++i) {
        gpuErrchk(cudaMalloc(&(A_gpu.dFBufs[i]), l * sizeof(Ftype)));
	    gpuErrchk(cudaMalloc(&(A_gpu.gpuGemmBuffs[i]), A_gpu.gemmBufferSize * sizeof(Ftype)));
	}
    
    
    // Wajih: Adding allocation for batched LU and SCU marshalled data
    // TODO: these are serialized workspaces, so the allocations can be shared
    
#if 0    
    A_gpu.marshall_data.setBatchSize(num_dfbufs);
    A_gpu.sc_marshall_data.setBatchSize(num_dfbufs);
#endif

    // TODO: where should these be freed?
    // Allocate GPU copy for the node list 
    gpuErrchk(cudaMalloc(&(A_gpu.dperm_c_supno), sizeof(int) * mx_fsize));
    // Allocate GPU copy of all the gemm buffer pointers and copy the host array to the GPU 
    gpuErrchk(cudaMalloc(&(A_gpu.dgpuGemmBuffs), sizeof(Ftype*) * num_gemmbufs));
    gpuErrchk(cudaMemcpy(A_gpu.dgpuGemmBuffs, A_gpu.gpuGemmBuffs, sizeof(Ftype*) * num_gemmbufs, cudaMemcpyHostToDevice));

    tcuMalloc = SuperLU_timer_() - tcuMalloc;
#if ( PRNTlevel>=1 )
    printf("Time to allocate GPU memory: %g\n", tcuMalloc);
    printf("\t.. sum_diag_size %d\t sum_gemmC_size %d\n", sum_diag_size, sum_gemmC_size);
    fflush(stdout);
#endif

    double tcuStream=SuperLU_timer_();
    
    for (stream = 0; stream < A_gpu.numCudaStreams; stream++)
    {
        // cublasCreate(&A_gpu.cuHandles[stream]);
        cusolverDnCreate(&A_gpu.cuSolveHandles[stream]);
    }
    tcuStream = SuperLU_timer_() - tcuStream;

    double tcuStreamCreate=SuperLU_timer_();
    for (stream = 0; stream < A_gpu.numCudaStreams; stream++)
    {
        cudaStreamCreate(&A_gpu.cuStreams[stream]);
        cublasCreate(&A_gpu.cuHandles[stream]);
        /*lookAhead buffers and stream*/
        cublasCreate(&A_gpu.lookAheadLHandle[stream]);
        cudaStreamCreate(&A_gpu.lookAheadLStream[stream]);
        cublasCreate(&A_gpu.lookAheadUHandle[stream]);
        cudaStreamCreate(&A_gpu.lookAheadUStream[stream]);

    }
    tcuStreamCreate = SuperLU_timer_() - tcuStreamCreate;
    tRegion[3] = SuperLU_timer_() - tRegion[3];
    
#if ( PRNTlevel >= 1 )
    printf("Time to create cublas streams: %g\n", tcuStream);
    printf("Time to create CUDA streams: %g\n", tcuStreamCreate);
    printf("Time taken to estimate memory on GPU: %f\n", tRegion[0]);
    printf("TRegion L,U send: \t %g\n", tRegion[1]);
    printf("Time to send Lpanel=%g  and U panels =%g \n", tLsend, tUsend);
    printf("TRegion dfactBuf: \t %g\n", tRegion[2]);
    printf("TRegion stream: \t %g\n", tRegion[3]);
    fflush(stdout);
#endif

    // allocate
    gpuErrchk(cudaMalloc(&dA_gpu, sizeof(xLUstructGPU_t<Ftype>)));
    gpuErrchk(cudaMemcpy(dA_gpu, &A_gpu, sizeof(xLUstructGPU_t<Ftype>), cudaMemcpyHostToDevice));

#endif /* match #if 0 ... #else ... */
    
    // cudaCheckError();
    
#if (DEBUGlevel >= 1)
	CHECK_MALLOC(iam, "Exit setLUstruct_GPU()");
#endif
    return 0;
} /* setLUstruct_GPU */

template <typename Ftype>
int_t xLUstruct_t<Ftype>::copyLUGPUtoHost()
{

    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
            lPanelVec[i].copyFromGPU();

    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            uPanelVec[i].copyFromGPU();
    return 0;
}

template <typename Ftype>
int_t xLUstruct_t<Ftype>::copyLUHosttoGPU()
{
    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
            lPanelVec[i].copyBackToGPU();

    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            uPanelVec[i].copyBackToGPU();
    return 0;
}

template <typename Ftype>
int_t xLUstruct_t<Ftype>::checkGPU()
{

    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
        lPanelVec[i].checkGPU();

    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        uPanelVec[i].checkGPU();

    std::cout << "Checking LU struct completed succesfully"
              << "\n";
    return 0;
}


/**
 * @brief Pack non-zero values into a vector.
 *
 * @param spNzvalArray The array of non-zero values.
 * @param nzvalSize The size of the array of non-zero values.
 * @param valOffset The offset of the non-zero values.
 * @param packedNzvals The vector to store the non-zero values.
 * @param packedNzvalsIndices The vector to store the indices of the non-zero values.
 */
template <typename Ftype>
void packNzvals(std::vector<Ftype> &packedNzvals, std::vector<int_t> &packedNzvalsIndices,
                Ftype *spNzvalArray, int_t nzvalSize, int_t valOffset)
{
    for (int k = 0; k < nzvalSize; k++)
    {
        if (spNzvalArray[k] != 0)
        {
            packedNzvals.push_back(spNzvalArray[k]);
            packedNzvalsIndices.push_back(valOffset + k);
        }
    }
}

const int AVOID_CPU_NZVAL = 1;
template <typename Ftype>
xlpanelGPU_t<Ftype> *xLUstruct_t<Ftype>::copyLpanelsToGPU()
{
    xlpanelGPU_t<Ftype> *lPanelVec_GPU = new xlpanelGPU_t<Ftype>[CEILING(nsupers, Pc)];

    // TODO: set gpuLvalSize, gpuLidxSize
    gpuLvalSize = 0;
    gpuLidxSize = 0;
    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
        {
            gpuLvalSize += sizeof(Ftype) * lPanelVec[i].nzvalSize();
            gpuLidxSize += sizeof(int_t) * lPanelVec[i].indexSize();
        }
    }

    Ftype *valBuffer = (Ftype *)SUPERLU_MALLOC(gpuLvalSize);
    int_t *idxBuffer = (int_t *)SUPERLU_MALLOC(gpuLidxSize);

    // allocate memory buffer on GPU
    gpuErrchk(cudaMalloc(&gpuLvalBasePtr, gpuLvalSize));
    gpuErrchk(cudaMalloc(&gpuLidxBasePtr, gpuLidxSize));

    size_t valOffset = 0;
    size_t idxOffset = 0;
    Ftype tCopyToCPU = SuperLU_timer_();

    std::vector<Ftype> packedNzvals;
    std::vector<int_t> packedNzvalsIndices;

    // do a memcpy to CPU buffer
    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
        {
            if (lPanelVec[i].isEmpty())
            {
                xlpanelGPU_t<Ftype> ithLpanel(NULL, NULL);
                lPanelVec[i].gpuPanel = ithLpanel;
                lPanelVec_GPU[i] = ithLpanel;
            }
            else
            {
                xlpanelGPU_t<Ftype> ithLpanel(&gpuLidxBasePtr[idxOffset], &gpuLvalBasePtr[valOffset]);
                lPanelVec[i].gpuPanel = ithLpanel;
                lPanelVec_GPU[i] = ithLpanel;
                if (AVOID_CPU_NZVAL)
                    packNzvals<Ftype>(packedNzvals, packedNzvalsIndices, lPanelVec[i].val, lPanelVec[i].nzvalSize(), valOffset);
                else
                    memcpy(&valBuffer[valOffset], lPanelVec[i].val, sizeof(Ftype) * lPanelVec[i].nzvalSize());

                memcpy(&idxBuffer[idxOffset], lPanelVec[i].index, sizeof(int_t) * lPanelVec[i].indexSize());

                valOffset += lPanelVec[i].nzvalSize();
                idxOffset += lPanelVec[i].indexSize();
            }
        }
    }
    tCopyToCPU = SuperLU_timer_() - tCopyToCPU;
    std::cout << "Time to copy-L to CPU: " << tCopyToCPU << "\n";
    // do a cudaMemcpy to GPU
    Ftype tLsend = SuperLU_timer_();
    if (AVOID_CPU_NZVAL)
        copyToGPU(gpuLvalBasePtr, packedNzvals, packedNzvalsIndices);
    else
    {
#if 0
            cudaMemcpy(gpuLvalBasePtr, valBuffer, gpuLvalSize, cudaMemcpyHostToDevice);
#else
        copyToGPU_Sparse(gpuLvalBasePtr, valBuffer, gpuLvalSize);
#endif
    }
    // find
    gpuErrchk(cudaMemcpy(gpuLidxBasePtr, idxBuffer, gpuLidxSize, cudaMemcpyHostToDevice));
    tLsend = SuperLU_timer_() - tLsend;
    printf("cudaMemcpy time L =%g \n", tLsend);

    SUPERLU_FREE(valBuffer);
    SUPERLU_FREE(idxBuffer);
    return lPanelVec_GPU;
} /* copyLpanelsToGPU */

template <typename Ftype>
xupanelGPU_t<Ftype> *xLUstruct_t<Ftype>::copyUpanelsToGPU()
{
#if (DEBUGlevel >= 1)
    int iam = 0;
    CHECK_MALLOC(iam, "Enter copyUpanelsToGPU()");
#endif
    
    xupanelGPU_t<Ftype> *uPanelVec_GPU = new xupanelGPU_t<Ftype>[CEILING(nsupers, Pr)];

    gpuUvalSize = 0;
    gpuUidxSize = 0;
    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
        {
            gpuUvalSize += sizeof(Ftype) * uPanelVec[i].nzvalSize();
            gpuUidxSize += sizeof(int_t) * uPanelVec[i].indexSize();
        }
    }

    // TODO: set gpuUvalSize, gpuUidxSize

    // allocate memory buffer on GPU
    gpuErrchk(cudaMalloc(&gpuUvalBasePtr, gpuUvalSize));
    gpuErrchk(cudaMalloc(&gpuUidxBasePtr, gpuUidxSize));

    size_t valOffset = 0;
    size_t idxOffset = 0;

    Ftype tCopyToCPU = SuperLU_timer_();
    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
        {
            if (uPanelVec[i].isEmpty())
            {
                xupanelGPU_t<Ftype> ithupanel(NULL, NULL);
                uPanelVec[i].gpuPanel = ithupanel;
                uPanelVec_GPU[i] = ithupanel;
            }
        }
    }

    int_t *idxBuffer = NULL;
    if ( gpuUidxSize>0 ) /* Sherry fix: gpuUidxSize can be 0 */
	idxBuffer = (int_t *)SUPERLU_MALLOC(gpuUidxSize);

    if (AVOID_CPU_NZVAL)
    {
        printf("AVOID_CPU_NZVAL is set\n");
        std::vector<Ftype> packedNzvals;
        std::vector<int_t> packedNzvalsIndices;
        for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        {
            if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            {
                if (!uPanelVec[i].isEmpty())
                {

                    xupanelGPU_t<Ftype> ithupanel(&gpuUidxBasePtr[idxOffset], &gpuUvalBasePtr[valOffset]);
                    uPanelVec[i].gpuPanel = ithupanel;
                    uPanelVec_GPU[i] = ithupanel;
                    packNzvals<Ftype>(packedNzvals, packedNzvalsIndices, uPanelVec[i].val,
                               uPanelVec[i].nzvalSize(), valOffset);
                    memcpy(&idxBuffer[idxOffset], uPanelVec[i].index, sizeof(int_t) * uPanelVec[i].indexSize());

                    valOffset += uPanelVec[i].nzvalSize();
                    idxOffset += uPanelVec[i].indexSize();
                }
            }
        }
        tCopyToCPU = SuperLU_timer_() - tCopyToCPU;
        printf("copyU to CPU-buff time = %g\n", tCopyToCPU);

        // do a cudaMemcpy to GPU
        Ftype tLsend = SuperLU_timer_();
        copyToGPU(gpuUvalBasePtr, packedNzvals, packedNzvalsIndices);
        gpuErrchk(cudaMemcpy(gpuUidxBasePtr, idxBuffer, gpuUidxSize, cudaMemcpyHostToDevice));
        tLsend = SuperLU_timer_() - tLsend;
        printf("cudaMemcpy time U =%g \n", tLsend);
        // SUPERLU_FREE(valBuffer);
    }
    else /* AVOID_CPU_NZVAL not set */
    {
        // do a memcpy to CPU buffer
        Ftype *valBuffer = (Ftype *)SUPERLU_MALLOC(gpuUvalSize);

        for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        {
            if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            {
                if (!uPanelVec[i].isEmpty())
                {

                    xupanelGPU_t<Ftype> ithupanel(&gpuUidxBasePtr[idxOffset], &gpuUvalBasePtr[valOffset]);
                    uPanelVec[i].gpuPanel = ithupanel;
                    uPanelVec_GPU[i] = ithupanel;
                    memcpy(&valBuffer[valOffset], uPanelVec[i].val, sizeof(Ftype) * uPanelVec[i].nzvalSize());
                    memcpy(&idxBuffer[idxOffset], uPanelVec[i].index, sizeof(int_t) * uPanelVec[i].indexSize());

                    valOffset += uPanelVec[i].nzvalSize();
                    idxOffset += uPanelVec[i].indexSize();
                }
            }
        }
        tCopyToCPU = SuperLU_timer_() - tCopyToCPU;
        printf("copyU to CPU-buff time = %g\n", tCopyToCPU);

        // do a cudaMemcpy to GPU
        Ftype tLsend = SuperLU_timer_();
        const int USE_GPU_COPY = 1;
        if (USE_GPU_COPY)
        {
            gpuErrchk(cudaMemcpy(gpuUvalBasePtr, valBuffer, gpuUvalSize, cudaMemcpyHostToDevice));
        }
        else
            copyToGPU_Sparse(gpuUvalBasePtr, valBuffer, gpuUvalSize);

        gpuErrchk(cudaMemcpy(gpuUidxBasePtr, idxBuffer, gpuUidxSize, cudaMemcpyHostToDevice));
        tLsend = SuperLU_timer_() - tLsend;
        printf("cudaMemcpy time U =%g \n", tLsend);

        SUPERLU_FREE(valBuffer);
    } /* end else AVOID_CPU_NZVAL not set */
    
    if ( gpuUidxSize>0 ) /* Sherry fix: gpuUidxSize can be 0 */
	SUPERLU_FREE(idxBuffer);

#if (DEBUGlevel >= 1)
    CHECK_MALLOC(iam, "Exit copyUpanelsToGPU()");
#endif
    
    return uPanelVec_GPU;
    
} /* copyUpanelsToGPU */
//#endif

