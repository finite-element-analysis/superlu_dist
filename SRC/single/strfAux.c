/*! \file
Copyright (c) 2003, The Regents of the University of California, through
Lawrence Berkeley National Laboratory (subject to receipt of any required
approvals from U.S. Dept. of Energy)

All rights reserved.

The source code is distributed under BSD license, see the file License.txt
at the top-level directory.
*/


/*! @file
 * \brief Auxiliary routine for 3D factorization.
 *
 * <pre>
 * -- Distributed SuperLU routine (version 9.0) --
 * Lawrence Berkeley National Lab, Georgia Institute of Technology,
 * Oak Ridge National Lab
 * May 12, 2021
 */

#include "superlu_sdefs.h"

#if 0
#include "pdgstrf3d.h"
#include "trfAux.h"
#endif

/* Inititalize the data structure to assist HALO offload of Schur-complement. */
void sInit_HyP(superlu_dist_options_t *options, HyP_t* HyP, sLocalLU_t *Llu, int_t mcb, int_t mrb )
{
    HyP->last_offload = -1;
#if 0
    HyP->lookAhead_info = (Remain_info_t *) _mm_malloc((mrb) * sizeof(Remain_info_t), 64);

    HyP->lookAhead_L_buff = (float *) _mm_malloc( sizeof(float) * (Llu->bufmax[1]), 64);

    HyP->Remain_L_buff = (float *) _mm_malloc( sizeof(float) * (Llu->bufmax[1]), 64);
    HyP->Remain_info = (Remain_info_t *) _mm_malloc(mrb * sizeof(Remain_info_t), 64);
    HyP->Ublock_info_Phi = (Ublock_info_t *) _mm_malloc(mcb * sizeof(Ublock_info_t), 64);
    HyP->Ublock_info = (Ublock_info_t *) _mm_malloc(mcb * sizeof(Ublock_info_t), 64);
    HyP->Lblock_dirty_bit = (int_t *) _mm_malloc(mcb * sizeof(int_t), 64);
    HyP->Ublock_dirty_bit = (int_t *) _mm_malloc(mrb * sizeof(int_t), 64);
#else
    HyP->lookAhead_info = (Remain_info_t *) SUPERLU_MALLOC((mrb) * sizeof(Remain_info_t));
    HyP->lookAhead_L_buff = (float *) floatMalloc_dist((Llu->bufmax[1]));
    HyP->Remain_L_buff = (float *) floatMalloc_dist((Llu->bufmax[1]));
    HyP->Remain_info = (Remain_info_t *) SUPERLU_MALLOC(mrb * sizeof(Remain_info_t));
    HyP->Ublock_info_Phi = (Ublock_info_t *) SUPERLU_MALLOC(mcb * sizeof(Ublock_info_t));
    HyP->Ublock_info = (Ublock_info_t *) SUPERLU_MALLOC(mcb * sizeof(Ublock_info_t));
    HyP->Lblock_dirty_bit = (int_t *) intMalloc_dist(mcb);
    HyP->Ublock_dirty_bit = (int_t *) intMalloc_dist(mrb);
#endif

    for (int_t i = 0; i < mcb; ++i)
    {
        HyP->Lblock_dirty_bit[i] = -1;
    }

    for (int_t i = 0; i < mrb; ++i)
    {
        HyP->Ublock_dirty_bit[i] = -1;
    }

    HyP->last_offload = -1;
    HyP->superlu_acc_offload = sp_ienv_dist(10, options); // get_acc_offload();

    HyP->nGPUStreams =0;
} /* sInit_HyP */

/*init3DLUstruct with forest interface */
void sinit3DLUstructForest( int_t* myTreeIdxs, int_t* myZeroTrIdxs,
                           sForest_t**  sForests, sLUstruct_t* LUstruct,
                           gridinfo3d_t* grid3d)
{
    int_t maxLvl = log2i(grid3d->zscp.Np) + 1;
    int_t numForests = (1 << maxLvl) - 1;
    int_t* gNodeCount = INT_T_ALLOC (numForests);
    int_t** gNodeLists =  (int_t**) SUPERLU_MALLOC(numForests * sizeof(int_t*));

    for (int i = 0; i < numForests; ++i)
	{
	    gNodeCount[i] = 0;
	    gNodeLists[i] = NULL;
	    /* code */
	    if (sForests[i])
		{
                    gNodeCount[i] = sForests[i]->nNodes;
		    gNodeLists[i] = sForests[i]->nodeList;
		}
	}

    /*call the old forest*/
    sinit3DLUstruct( myTreeIdxs, myZeroTrIdxs,
		     gNodeCount, gNodeLists, LUstruct, grid3d);

    SUPERLU_FREE(gNodeCount);  // sherry added
    SUPERLU_FREE(gNodeLists);
}

int_t sSchurComplementSetup(
    int_t k,
    int *msgcnt,
    Ublock_info_t*  Ublock_info,
    Remain_info_t*  Remain_info,
    uPanelInfo_t *uPanelInfo,
    lPanelInfo_t *lPanelInfo,
    int_t* iperm_c_supno,
    int_t * iperm_u,
    int_t * perm_u,
    float *bigU,
    int_t* Lsub_buf,
    float *Lval_buf,
    int_t* Usub_buf,
    float *Uval_buf,
    gridinfo_t *grid,
    sLUstruct_t *LUstruct
)
{
    Glu_persist_t *Glu_persist = LUstruct->Glu_persist;
    sLocalLU_t *Llu = LUstruct->Llu;
    int_t* xsup = Glu_persist->xsup;

    int* ToRecv = Llu->ToRecv;
    int_t iam = grid->iam;

    int_t myrow = MYROW (iam, grid);
    int_t mycol = MYCOL (iam, grid);

    int_t krow = PROW (k, grid);
    int_t kcol = PCOL (k, grid);
    int_t** Lrowind_bc_ptr = Llu->Lrowind_bc_ptr;
    float** Lnzval_bc_ptr = Llu->Lnzval_bc_ptr;

    int_t** Ufstnz_br_ptr = Llu->Ufstnz_br_ptr;
    float** Unzval_br_ptr = Llu->Unzval_br_ptr;

    int_t *usub;
    float* uval;
    int_t* lsub;
    float* lusup;

    if (mycol == kcol)
    {
        /*send the L panel to myrow*/
        int_t  lk = LBj (k, grid);     /* Local block number. */
        lsub = Lrowind_bc_ptr[lk];
        lPanelInfo->lsub = Lrowind_bc_ptr[lk];
        lusup = Lnzval_bc_ptr[lk];
        lPanelInfo->lusup = Lnzval_bc_ptr[lk];
    }
    else
    {
        lsub = Lsub_buf;
        lPanelInfo->lsub = Lsub_buf;
        lusup = Lval_buf;
        lPanelInfo->lusup = Lval_buf;
    }

    if (myrow == krow)
    {
        int_t  lk = LBi (k, grid);
        usub = Ufstnz_br_ptr[lk];
        uval = Unzval_br_ptr[lk];
        uPanelInfo->usub = usub;
    }
    else
    {
        if (ToRecv[k] == 2)
        {
            usub = Usub_buf;
            uval = Uval_buf;
            uPanelInfo->usub = usub;
        }
    }

    /*now each procs does the schurcomplement update*/
    int_t msg0 = msgcnt[0];
    int_t msg2 = msgcnt[2];
    int_t knsupc = SuperSize (k);

    int_t lptr0, luptr0;
    int_t LU_nonempty = msg0 && msg2;
    if (LU_nonempty == 0) return 0;
    if (msg0 && msg2)       /* L(:,k) and U(k,:) are not empty. */
    {
        lPanelInfo->nsupr = lsub[1];
        int_t nlb;
        if (myrow == krow)  /* Skip diagonal block L(k,k). */
        {
            lptr0 = BC_HEADER + LB_DESCRIPTOR + lsub[BC_HEADER + 1];
            luptr0 = knsupc;
            nlb = lsub[0] - 1;
            lPanelInfo->nlb = nlb;
        }
        else
        {
            lptr0 = BC_HEADER;
            luptr0 = 0;
            nlb = lsub[0];
            lPanelInfo->nlb = nlb;
        }
        int_t iukp = BR_HEADER;   /* Skip header; Pointer to index[] of U(k,:) */
        int_t rukp = 0;           /* Pointer to nzval[] of U(k,:) */
        int_t nub = usub[0];      /* Number of blocks in the block row U(k,:) */
        int_t klst = FstBlockC (k + 1);
        uPanelInfo->klst = klst;

        /* --------------------------------------------------------------
           Update the look-ahead block columns A(:,k+1:k+num_look_ahead).
           -------------------------------------------------------------- */
        int_t iukp0 = iukp;
        int_t rukp0 = rukp;

        /* reorder the remaining columns in bottom-up */
        for (int_t jj = 0; jj < nub; jj++)
        {
#ifdef ISORT
            iperm_u[jj] = iperm_c_supno[usub[iukp]];    /* Global block number of block U(k,j). */
            perm_u[jj] = jj;
#else
            perm_u[2 * jj] = iperm_c_supno[usub[iukp]]; /* Global block number of block U(k,j). */
            perm_u[2 * jj + 1] = jj;
#endif
            int jb = usub[iukp];    /* Global block number of block U(k,j). */
            int nsupc = SuperSize (jb);
            iukp += UB_DESCRIPTOR;  /* Start fstnz of block U(k,j). */
            iukp += nsupc;
        }
        iukp = iukp0;
#ifdef ISORT
        isort (nub, iperm_u, perm_u);
#else
        qsort (perm_u, (size_t) nub, 2 * sizeof (int_t),
               &superlu_sort_perm);
#endif
        // j = jj0 = 0;

        int_t ldu   = 0;
        int_t full  = 1;
        int_t num_u_blks = 0;

        for (int_t j = 0; j < nub ; ++j)
        {
            int_t iukp, temp_ncols;

            temp_ncols = 0;
            int_t  rukp;
	    int jb, ljb, nsupc, segsize;
            arrive_at_ublock(
                j, &iukp, &rukp, &jb, &ljb, &nsupc,
                iukp0, rukp0, usub, perm_u, xsup, grid
            );

            int_t jj = iukp;
            for (; jj < iukp + nsupc; ++jj)
            {
                segsize = klst - usub[jj];
                if ( segsize ) ++temp_ncols;
            }
            Ublock_info[num_u_blks].iukp = iukp;
            Ublock_info[num_u_blks].rukp = rukp;
            Ublock_info[num_u_blks].jb = jb;
            Ublock_info[num_u_blks].eo = iperm_c_supno[jb];
            /* Prepare to call DGEMM. */
            jj = iukp;

            for (; jj < iukp + nsupc; ++jj)
            {
                segsize = klst - usub[jj];
                if ( segsize )
                {
                    if ( segsize != ldu ) full = 0;
                    if ( segsize > ldu ) ldu = segsize;
                }
            }

            Ublock_info[num_u_blks].ncols = temp_ncols;
            // ncols += temp_ncols;
            num_u_blks++;

        }

        uPanelInfo->ldu = ldu;
        uPanelInfo->nub = num_u_blks;

        Ublock_info[0].full_u_cols = Ublock_info[0 ].ncols;
        Ublock_info[0].StCol = 0;
        for ( int_t j = 1; j < num_u_blks; ++j)
        {
            Ublock_info[j].full_u_cols = Ublock_info[j ].ncols + Ublock_info[j - 1].full_u_cols;
            Ublock_info[j].StCol = Ublock_info[j - 1].StCol + Ublock_info[j - 1].ncols;
        }

        sgather_u(num_u_blks, Ublock_info, usub,  uval,  bigU,  ldu, xsup, klst );

        sort_U_info_elm(Ublock_info, num_u_blks );

        int_t cum_nrow = 0;
        int_t RemainBlk = 0;

        int_t lptr = lptr0;
        int_t luptr = luptr0;
        for (int_t i = 0; i < nlb; ++i)
        {
            int_t ib = lsub[lptr];        /* Row block L(i,k). */
            int_t temp_nbrow = lsub[lptr + 1]; /* Number of full rows. */

            Remain_info[RemainBlk].nrows = temp_nbrow;
            Remain_info[RemainBlk].StRow = cum_nrow;
            Remain_info[RemainBlk].FullRow = cum_nrow;
            Remain_info[RemainBlk].lptr = lptr;
            Remain_info[RemainBlk].ib = ib;
            Remain_info[RemainBlk].eo = iperm_c_supno[ib];
            RemainBlk++;

            cum_nrow += temp_nbrow;
            lptr += LB_DESCRIPTOR;  /* Skip descriptor. */
            lptr += temp_nbrow;
            luptr += temp_nbrow;
        }

        lptr = lptr0;
        luptr = luptr0;
        sort_R_info_elm( Remain_info, lPanelInfo->nlb );
        lPanelInfo->luptr0 = luptr0;
    }
    return LU_nonempty;
} /* sSchurComplementSetup */

/*
 * Gather L and U panels into respective buffers, to prepare for GEMM call.
 * Divide Schur complement update into two parts: CPU vs. GPU.
 */
int_t sSchurComplementSetupGPU(
    int_t k, msgs_t* msgs,
    packLUInfo_t* packLUInfo,
    int_t* myIperm,
    int_t* iperm_c_supno, int_t*perm_c_supno,
    gEtreeInfo_t*   gEtreeInfo, factNodelists_t* fNlists,
    sscuBufs_t* scuBufs, sLUValSubBuf_t* LUvsb,
    gridinfo_t *grid, sLUstruct_t *LUstruct,
    HyP_t* HyP)
{
    int_t * Lsub_buf  = LUvsb->Lsub_buf;
    float * Lval_buf  = LUvsb->Lval_buf;
    int_t * Usub_buf  = LUvsb->Usub_buf;
    float * Uval_buf  = LUvsb->Uval_buf;
    uPanelInfo_t* uPanelInfo = packLUInfo->uPanelInfo;
    lPanelInfo_t* lPanelInfo = packLUInfo->lPanelInfo;
    int* msgcnt  = msgs->msgcnt;
    int_t* iperm_u  = fNlists->iperm_u;
    int_t* perm_u  = fNlists->perm_u;
    float* bigU = scuBufs->bigU;

    Glu_persist_t *Glu_persist = LUstruct->Glu_persist;
    sLocalLU_t *Llu = LUstruct->Llu;
    int_t* xsup = Glu_persist->xsup;

    int* ToRecv = Llu->ToRecv;
    int_t iam = grid->iam;

    int_t myrow = MYROW (iam, grid);
    int_t mycol = MYCOL (iam, grid);

    int_t krow = PROW (k, grid);
    int_t kcol = PCOL (k, grid);
    int_t** Lrowind_bc_ptr = Llu->Lrowind_bc_ptr;
    float** Lnzval_bc_ptr = Llu->Lnzval_bc_ptr;

    int_t** Ufstnz_br_ptr = Llu->Ufstnz_br_ptr;
    float** Unzval_br_ptr = Llu->Unzval_br_ptr;

    int_t *usub;
    float* uval;
    int_t* lsub;
    float* lusup;

    HyP->lookAheadBlk = 0, HyP->RemainBlk = 0;
    HyP->Lnbrow =0, HyP->Rnbrow=0;
    HyP->num_u_blks_Phi=0;
    HyP->num_u_blks=0;

    if (mycol == kcol)
    {
        /*send the L panel to myrow*/
        int_t  lk = LBj (k, grid);     /* Local block number. */
        lsub = Lrowind_bc_ptr[lk];
        lPanelInfo->lsub = Lrowind_bc_ptr[lk];
        lusup = Lnzval_bc_ptr[lk];
        lPanelInfo->lusup = Lnzval_bc_ptr[lk];
    }
    else
    {
        lsub = Lsub_buf;
        lPanelInfo->lsub = Lsub_buf;
        lusup = Lval_buf;
        lPanelInfo->lusup = Lval_buf;
    }
    if (myrow == krow)
    {
        int_t  lk = LBi (k, grid);
        usub = Ufstnz_br_ptr[lk];
        uval = Unzval_br_ptr[lk];
        uPanelInfo->usub = usub;
    }
    else
    {
        if (ToRecv[k] == 2)
        {
            usub = Usub_buf;
            uval = Uval_buf;
            uPanelInfo->usub = usub;
        }
    }

    /*now each procs does the schurcomplement update*/
    int_t msg0 = msgcnt[0];
    int_t msg2 = msgcnt[2];
    int_t knsupc = SuperSize (k);

    int_t lptr0, luptr0;
    int_t LU_nonempty = msg0 && msg2;
    if (LU_nonempty == 0) return 0;
    if (msg0 && msg2)       /* L(:,k) and U(k,:) are not empty. */
    {
        lPanelInfo->nsupr = lsub[1];
        int_t nlb;
        if (myrow == krow)  /* Skip diagonal block L(k,k). */
        {
            lptr0 = BC_HEADER + LB_DESCRIPTOR + lsub[BC_HEADER + 1];
            luptr0 = knsupc;
            nlb = lsub[0] - 1;
            lPanelInfo->nlb = nlb;
        }
        else
        {
            lptr0 = BC_HEADER;
            luptr0 = 0;
            nlb = lsub[0];
            lPanelInfo->nlb = nlb;
        }
        int_t iukp = BR_HEADER;   /* Skip header; Pointer to index[] of U(k,:) */

        int_t nub = usub[0];      /* Number of blocks in the block row U(k,:) */
        int_t klst = FstBlockC (k + 1);
        uPanelInfo->klst = klst;

        /* --------------------------------------------------------------
           Update the look-ahead block columns A(:,k+1:k+num_look_ahead).
           -------------------------------------------------------------- */
        int_t iukp0 = iukp;

        /* reorder the remaining columns in bottom-up */
        for (int_t jj = 0; jj < nub; jj++)
        {
#ifdef ISORT
            iperm_u[jj] = iperm_c_supno[usub[iukp]];    /* Global block number of block U(k,j). */
            perm_u[jj] = jj;
#else
            perm_u[2 * jj] = iperm_c_supno[usub[iukp]]; /* Global block number of block U(k,j). */
            perm_u[2 * jj + 1] = jj;
#endif
            int_t jb = usub[iukp];    /* Global block number of block U(k,j). */
            int_t nsupc = SuperSize (jb);
            iukp += UB_DESCRIPTOR;  /* Start fstnz of block U(k,j). */
            iukp += nsupc;
        }
        iukp = iukp0;
#ifdef ISORT
        isort (nub, iperm_u, perm_u);
#else
        qsort (perm_u, (size_t) nub, 2 * sizeof (int_t),
               &superlu_sort_perm);
#endif
        HyP->Lnbrow = 0;
        HyP->Rnbrow = 0;
        HyP->num_u_blks_Phi=0;
	HyP->num_u_blks=0;

        sRgather_L(k, lsub, lusup,  gEtreeInfo, Glu_persist, grid, HyP, myIperm, iperm_c_supno);
        if (HyP->Lnbrow + HyP->Rnbrow > 0)
        {
            sRgather_U( k, 0, usub, uval, bigU,  gEtreeInfo, Glu_persist, grid, HyP, myIperm, iperm_c_supno, perm_u);
        }/*if(nbrow>0) */

    }

    return LU_nonempty;
} /* sSchurComplementSetupGPU */


float* sgetBigV(int_t ldt, int_t num_threads)
{
    float *bigV;
    if (!(bigV = floatMalloc_dist (8 * ldt * ldt * num_threads)))
        ABORT ("Malloc failed for dgemm buffV");
    return bigV;
}

float* sgetBigU(superlu_dist_options_t *options,
	 int_t nsupers, gridinfo_t *grid, sLUstruct_t *LUstruct)
{
    int_t Pr = grid->nprow;
    int_t Pc = grid->npcol;
    int_t iam = grid->iam;
    int_t mycol = MYCOL (iam, grid);

    /* Following circuit is for finding maximum block size */
    int local_max_row_size = 0;
    int max_row_size;

    for (int_t i = 0; i < nsupers; ++i)
    {
        int_t tpc = PCOL (i, grid);
        if (mycol == tpc)
        {
            int_t lk = LBj (i, grid);
            int_t* lsub = LUstruct->Llu->Lrowind_bc_ptr[lk];
            if (lsub != NULL)
            {
                local_max_row_size = SUPERLU_MAX (local_max_row_size, lsub[1]);
            }
        }

    }

    /* Max row size is global reduction of within A row */
    MPI_Allreduce (&local_max_row_size, &max_row_size, 1, MPI_INT, MPI_MAX,
                   (grid->rscp.comm));

    // int_t Threads_per_process = get_thread_per_process ();

    /*Buffer size is max of of look ahead window*/

    int_t bigu_size =
	8 * sp_ienv_dist(3, options) * (max_row_size) * SUPERLU_MAX(Pr / Pc, 1);
	//Sherry: 8 * sp_ienv_dist (3) * (max_row_size) * MY_MAX(Pr / Pc, 1);

    // printf("Size of big U is %d\n",bigu_size );
    float* bigU = floatMalloc_dist(bigu_size);

    return bigU;
} /* sgetBigU */

#if 0
/* YL: Initialize 3Dpartition using only LUstruct on grid 0. Note that this is a function modifed based on dinitTrf3Dpartition */
strf3Dpartition_t* sinitTrf3DpartitionLUstructgrid0(int_t n, superlu_dist_options_t *options,
				      sLUstruct_t *LUstruct, gridinfo3d_t * grid3d
				      )
{
    gridinfo_t* grid = &(grid3d->grid2d);
    int iam = grid3d->iam;
#if ( DEBUGlevel>=1 )
    CHECK_MALLOC (iam, "Enter sinitTrf3DpartitionLUstructgrid0()");
#endif
    int_t nsupers;
    int_t *setree;
    if (!grid3d->zscp.Iam){
        nsupers = getNsupers(n, LUstruct->Glu_persist);
        setree = supernodal_etree(nsupers, LUstruct->etree, LUstruct->Glu_persist->supno, LUstruct->Glu_persist->xsup);
    }

    MPI_Bcast( &nsupers, 1, mpi_int_t, 0,  grid3d->zscp.comm);
    zAllocBcast(nsupers * sizeof (int_t), (void**)&(setree), grid3d);

    int_t* iperm_c_supno;
    int_t *xsup;
    if (!grid3d->zscp.Iam){
        int_t* perm_c_supno = getPerm_c_supno(nsupers, options,
                                         LUstruct->etree,
    	   		                 LUstruct->Glu_persist,
		                         LUstruct->Llu->Lrowind_bc_ptr,
					 LUstruct->Llu->Ufstnz_br_ptr, grid);
        iperm_c_supno = getFactIperm(perm_c_supno, nsupers);
        SUPERLU_FREE(perm_c_supno);
        xsup  = LUstruct->Glu_persist->xsup;
    }
    zAllocBcast(nsupers * sizeof (int_t), (void**)&(iperm_c_supno), grid3d);
    zAllocBcast((nsupers+1) * sizeof (int_t), (void**)&(xsup), grid3d);


    treeList_t* treeList = setree2list(nsupers, setree );
    if (!grid3d->zscp.Iam){
        /*update treelist with weight and depth*/
        getSCUweight(nsupers, treeList, xsup,
            LUstruct->Llu->Lrowind_bc_ptr, LUstruct->Llu->Ufstnz_br_ptr,
            grid3d);
        int_t * scuWeight = intCalloc_dist(nsupers);
        for (int_t k = 0; k < nsupers ; ++k)
        {
            scuWeight[k] = treeList[k].scuWeight;
        }
        MPI_Bcast(scuWeight, nsupers, mpi_int_t, 0,  grid3d->zscp.comm);
    }else{
        gridinfo_t* grid = &(grid3d->grid2d);
        int_t * scuWeight = intCalloc_dist(nsupers);
        MPI_Bcast(scuWeight, nsupers, mpi_int_t, 0,  grid3d->zscp.comm);
        for (int_t k = 0; k < nsupers ; ++k)
        {
            treeList[k].scuWeight = scuWeight[k];
        }
        SUPERLU_FREE(scuWeight);
    }
    calcTreeWeight(nsupers, setree, treeList, xsup);

    if (grid3d->zscp.Iam){
        SUPERLU_FREE(xsup);
    }

    gEtreeInfo_t gEtreeInfo;
    gEtreeInfo.setree = setree;
    gEtreeInfo.numChildLeft = (int_t* ) SUPERLU_MALLOC(sizeof(int_t) * nsupers);
    for (int_t i = 0; i < nsupers; ++i)
    {
        /* code */
        gEtreeInfo.numChildLeft[i] = treeList[i].numChild;
    }

    int maxLvl = log2i(grid3d->zscp.Np) + 1; /* Levels for Pz process layer */
    sForest_t**  sForests = getForests( maxLvl, nsupers, setree, treeList);
    /*indexes of trees for my process grid in gNodeList size(maxLvl)*/
    int_t* myTreeIdxs = getGridTrees(grid3d);
    int_t* myZeroTrIdxs = getReplicatedTrees(grid3d);
    int_t*  gNodeCount = getNodeCountsFr(maxLvl, sForests);
    int_t** gNodeLists = getNodeListFr(maxLvl, sForests); // reuse NodeLists stored in sForests[]


    int_t* myNodeCount = getMyNodeCountsFr(maxLvl, myTreeIdxs, sForests);
    int_t** treePerm = getTreePermFr( myTreeIdxs, sForests, grid3d);


    int_t* supernode2treeMap = SUPERLU_MALLOC(nsupers*sizeof(int_t));
    int_t numForests = (1 << maxLvl) - 1;
    for (int_t Fr = 0; Fr < numForests; ++Fr)
    {
        /* code */
        for (int_t nd = 0; nd < gNodeCount[Fr]; ++nd)
        {
            /* code */
            supernode2treeMap[gNodeLists[Fr][nd]]=Fr;
        }
    }

    int* supernodeMask = SUPERLU_MALLOC(nsupers*sizeof(int));
    for (int ii = 0; ii < nsupers; ++ii)
        supernodeMask[ii]=0;
    for (int lvl = 0; lvl < maxLvl; ++lvl)
    {
        // printf("iam %5d lvl %5d myNodeCount[lvl] %5d\n",grid3d->iam, lvl,myNodeCount[lvl]);
        for (int nd = 0; nd < myNodeCount[lvl]; ++nd)
        {
            supernodeMask[treePerm[lvl][nd]]=1;
        }
    }


    /* Sherry 2/17/23
       Compute buffer sizes needed for diagonal LU blocks and C matrices in GEMM. */


    iam = grid->iam;  /* 'grid' is 2D grid */
    int k, k0, k_st, k_end, offset, nsupc, krow, kcol;
    int myrow = MYROW (iam, grid);
    int mycol = MYCOL (iam, grid);

#if 0
    int krow = PROW (k, grid);
    int kcol = PCOL (k, grid);
    int_t** Lrowind_bc_ptr = Llu->Lrowind_bc_ptr;
    double** Lnzval_bc_ptr = Llu->Lnzval_bc_ptr;

    int_t** Ufstnz_br_ptr = Llu->Ufstnz_br_ptr;
    double** Unzval_br_ptr = Llu->Unzval_br_ptr;
#endif

    int mxLeafNode = 0; // Yang: only need to check the leaf level of topoInfo as the factorization proceeds level by level
    for (int ilvl = 0; ilvl < maxLvl; ++ilvl) {
        if (sForests[myTreeIdxs[ilvl]] && sForests[myTreeIdxs[ilvl]]->topoInfo.eTreeTopLims[1] > mxLeafNode )
            mxLeafNode    = sForests[myTreeIdxs[ilvl]]->topoInfo.eTreeTopLims[1];
    }

    // Yang: use ldts to track the maximum needed buffer sizes per node of topoInfo
    //int *ldts = (int*) SUPERLU_MALLOC(mxLeafNode*sizeof(int));
    //for (int i = 0; i < mxLeafNode; ++i) {  //????????
    //ldts[i]=1;
    //}
    int *ldts = int32Calloc_dist(mxLeafNode);

    for (int ilvl = 0; ilvl < maxLvl; ++ilvl) {  /* Loop through the Pz tree levels */
        int treeId = myTreeIdxs[ilvl];
        sForest_t* sforest = sForests[treeId];
        if (sforest){
            int_t *perm_node = sforest->nodeList ; /* permuted list, in order of factorization */
	    int maxTopoLevel = sforest->topoInfo.numLvl;/* number of levels at each outer-tree node */
            for (int topoLvl = 0; topoLvl < maxTopoLevel; ++topoLvl)
            {
                /* code */
                k_st = sforest->topoInfo.eTreeTopLims[topoLvl];
                k_end = sforest->topoInfo.eTreeTopLims[topoLvl + 1];
		//printf("\t..topoLvl %d, k_st %d, k_end %d\n", topoLvl, k_st, k_end);

                for (int k0 = k_st; k0 < k_end; ++k0)
                {
                    offset = k0 - k_st;
                    k = perm_node[k0];
                    nsupc = SuperSize (k);
                    krow = PROW (k, grid);
                    kcol = PCOL (k, grid);
                    if ( myrow == krow || mycol == kcol )  /* diagonal process */
                    {
		        ldts[offset] = SUPERLU_MAX(ldts[offset], nsupc);
                    }
#if 0 /* GPU gemm buffers can only be set on GPU side, because here we only know
	 the size of U data structure on CPU.  It is different on GPU */
                    if ( mycol == kcol ) { /* processes owning L panel */

		    }
                    if ( myrow == krow )
			gemmCsizes[offset] = SUPERLU_MAX(ldts[offset], ???);
#endif
                }
            }
        }
    }

    //PrintInt10("inittrf3Dpartition: ldts", mxLeafNode, ldts);

    strf3Dpartition_t*  trf3Dpartition = SUPERLU_MALLOC(sizeof(strf3Dpartition_t));

    trf3Dpartition->gEtreeInfo = gEtreeInfo;
    trf3Dpartition->iperm_c_supno = iperm_c_supno;
    trf3Dpartition->myNodeCount = myNodeCount;
    trf3Dpartition->myTreeIdxs = myTreeIdxs;
    trf3Dpartition->myZeroTrIdxs = myZeroTrIdxs;
    trf3Dpartition->sForests = sForests;
    trf3Dpartition->treePerm = treePerm;
    trf3Dpartition->maxLvl = maxLvl;
    // trf3Dpartition->LUvsb = LUvsb;
    trf3Dpartition->supernode2treeMap = supernode2treeMap;
    trf3Dpartition->supernodeMask = supernodeMask;
    trf3Dpartition->mxLeafNode = mxLeafNode;  // Sherry added these 3
    trf3Dpartition->diagDims = ldts;
    //trf3Dpartition->gemmCsizes = gemmCsizes;

    // Sherry added
    // Deallocate storage
    SUPERLU_FREE(gNodeCount);
    SUPERLU_FREE(gNodeLists);
    free_treelist(nsupers, treeList);

#if ( DEBUGlevel>=1 )
    CHECK_MALLOC (iam, "Exit sinitTrf3DpartitionLUstructgrid0()");
#endif
    return trf3Dpartition;
} /* sinitTrf3DpartitionLUstructgrid0 */

/* YL: Initialize 3Dpartition using LUstruct on all grid. LUstruct has partial L and U meta data from a supernodemask array that assigns the supernodes on z grid in the round-robin fashion. Note that this is a function modifed based on dinitTrf3Dpartition */
strf3Dpartition_t* sinitTrf3Dpartition_allgrid(int_t n, superlu_dist_options_t *options,
				      sLUstruct_t *LUstruct, gridinfo3d_t * grid3d
				      )
{
    gridinfo_t* grid = &(grid3d->grid2d);
    int iam = grid3d->iam;
#if ( DEBUGlevel>=1 )
    CHECK_MALLOC (iam, "Enter sinitTrf3Dpartition_allgrid()");
#endif
    int_t nsupers;
    int_t *setree;

    nsupers = getNsupers(n, LUstruct->Glu_persist);
    setree = supernodal_etree(nsupers, LUstruct->etree, LUstruct->Glu_persist->supno, LUstruct->Glu_persist->xsup);

    int_t* iperm_c_supno;
    int_t *xsup;
    int_t* perm_c_supno = getPerm_c_supno_allgrid(nsupers, options,
                                        LUstruct->etree,
                                LUstruct->Glu_persist,
                                LUstruct->Llu->Lrowind_bc_ptr,
                    LUstruct->Llu->Ufstnz_br_ptr, grid3d);
    iperm_c_supno = getFactIperm(perm_c_supno, nsupers);
    SUPERLU_FREE(perm_c_supno);
    xsup  = LUstruct->Glu_persist->xsup;


    treeList_t* treeList = setree2list(nsupers, setree );

    /*update treelist with weight and depth*/
    getSCUweight_allgrid(nsupers, treeList, xsup,
        LUstruct->Llu->Lrowind_bc_ptr, LUstruct->Llu->Ufstnz_br_ptr,
        grid3d);

    calcTreeWeight(nsupers, setree, treeList, xsup);

    gEtreeInfo_t gEtreeInfo;
    gEtreeInfo.setree = setree;
    gEtreeInfo.numChildLeft = (int_t* ) SUPERLU_MALLOC(sizeof(int_t) * nsupers);
    for (int_t i = 0; i < nsupers; ++i)
    {
        /* code */
        gEtreeInfo.numChildLeft[i] = treeList[i].numChild;
    }

    int maxLvl = log2i(grid3d->zscp.Np) + 1; /* Levels for Pz process layer */
    sForest_t**  sForests = getForests( maxLvl, nsupers, setree, treeList);
    /*indexes of trees for my process grid in gNodeList size(maxLvl)*/
    int_t* myTreeIdxs = getGridTrees(grid3d);
    int_t* myZeroTrIdxs = getReplicatedTrees(grid3d);
    int_t*  gNodeCount = getNodeCountsFr(maxLvl, sForests);
    int_t** gNodeLists = getNodeListFr(maxLvl, sForests); // reuse NodeLists stored in sForests[]


    int_t* myNodeCount = getMyNodeCountsFr(maxLvl, myTreeIdxs, sForests);
    int_t** treePerm = getTreePermFr( myTreeIdxs, sForests, grid3d);


    int_t* supernode2treeMap = SUPERLU_MALLOC(nsupers*sizeof(int_t));
    int_t numForests = (1 << maxLvl) - 1;
    for (int_t Fr = 0; Fr < numForests; ++Fr)
    {
        /* code */
        for (int_t nd = 0; nd < gNodeCount[Fr]; ++nd)
        {
            /* code */
            supernode2treeMap[gNodeLists[Fr][nd]]=Fr;
        }
    }

    int* supernodeMask = SUPERLU_MALLOC(nsupers*sizeof(int));
    for (int ii = 0; ii < nsupers; ++ii)
        supernodeMask[ii]=0;
    for (int lvl = 0; lvl < maxLvl; ++lvl)
    {
        // printf("iam %5d lvl %5d myNodeCount[lvl] %5d\n",grid3d->iam, lvl,myNodeCount[lvl]);
        for (int nd = 0; nd < myNodeCount[lvl]; ++nd)
        {
            supernodeMask[treePerm[lvl][nd]]=1;
        }
    }


    /* Sherry 2/17/23
       Compute buffer sizes needed for diagonal LU blocks and C matrices in GEMM. */


    iam = grid->iam;  /* 'grid' is 2D grid */
    int k, k0, k_st, k_end, offset, nsupc, krow, kcol;
    int myrow = MYROW (iam, grid);
    int mycol = MYCOL (iam, grid);

#if 0
    int krow = PROW (k, grid);
    int kcol = PCOL (k, grid);
    int_t** Lrowind_bc_ptr = Llu->Lrowind_bc_ptr;
    double** Lnzval_bc_ptr = Llu->Lnzval_bc_ptr;

    int_t** Ufstnz_br_ptr = Llu->Ufstnz_br_ptr;
    double** Unzval_br_ptr = Llu->Unzval_br_ptr;
#endif

    int mxLeafNode = 0; // Yang: only need to check the leaf level of topoInfo as the factorization proceeds level by level
    for (int ilvl = 0; ilvl < maxLvl; ++ilvl) {
        if (sForests[myTreeIdxs[ilvl]] && sForests[myTreeIdxs[ilvl]]->topoInfo.eTreeTopLims[1] > mxLeafNode )
            mxLeafNode    = sForests[myTreeIdxs[ilvl]]->topoInfo.eTreeTopLims[1];
    }

    // Yang: use ldts to track the maximum needed buffer sizes per node of topoInfo
    //int *ldts = (int*) SUPERLU_MALLOC(mxLeafNode*sizeof(int));
    //for (int i = 0; i < mxLeafNode; ++i) {  //????????
    //ldts[i]=1;
    //}
    int *ldts = int32Calloc_dist(mxLeafNode);

    for (int ilvl = 0; ilvl < maxLvl; ++ilvl) {  /* Loop through the Pz tree levels */
        int treeId = myTreeIdxs[ilvl];
        sForest_t* sforest = sForests[treeId];
        if (sforest){
            int_t *perm_node = sforest->nodeList ; /* permuted list, in order of factorization */
	    int maxTopoLevel = sforest->topoInfo.numLvl;/* number of levels at each outer-tree node */
            for (int topoLvl = 0; topoLvl < maxTopoLevel; ++topoLvl)
            {
                /* code */
                k_st = sforest->topoInfo.eTreeTopLims[topoLvl];
                k_end = sforest->topoInfo.eTreeTopLims[topoLvl + 1];
		//printf("\t..topoLvl %d, k_st %d, k_end %d\n", topoLvl, k_st, k_end);

                for (int k0 = k_st; k0 < k_end; ++k0)
                {
                    offset = k0 - k_st;
                    k = perm_node[k0];
                    nsupc = SuperSize (k);
                    krow = PROW (k, grid);
                    kcol = PCOL (k, grid);
                    if ( myrow == krow || mycol == kcol )  /* diagonal process */
                    {
		        ldts[offset] = SUPERLU_MAX(ldts[offset], nsupc);
                    }
#if 0 /* GPU gemm buffers can only be set on GPU side, because here we only know
	 the size of U data structure on CPU.  It is different on GPU */
                    if ( mycol == kcol ) { /* processes owning L panel */

		    }
                    if ( myrow == krow )
			gemmCsizes[offset] = SUPERLU_MAX(ldts[offset], ???);
#endif
                }
            }
        }
    }

    //PrintInt10("inittrf3Dpartition: ldts", mxLeafNode, ldts);

    strf3Dpartition_t*  trf3Dpartition = SUPERLU_MALLOC(sizeof(strf3Dpartition_t));

    trf3Dpartition->gEtreeInfo = gEtreeInfo;
    trf3Dpartition->iperm_c_supno = iperm_c_supno;
    trf3Dpartition->myNodeCount = myNodeCount;
    trf3Dpartition->myTreeIdxs = myTreeIdxs;
    trf3Dpartition->myZeroTrIdxs = myZeroTrIdxs;
    trf3Dpartition->sForests = sForests;
    trf3Dpartition->treePerm = treePerm;
    trf3Dpartition->maxLvl = maxLvl;
    // trf3Dpartition->LUvsb = LUvsb;
    trf3Dpartition->supernode2treeMap = supernode2treeMap;
    trf3Dpartition->supernodeMask = supernodeMask;
    trf3Dpartition->mxLeafNode = mxLeafNode;  // Sherry added these 3
    trf3Dpartition->diagDims = ldts;
    //trf3Dpartition->gemmCsizes = gemmCsizes;

    // Sherry added
    // Deallocate storage
    SUPERLU_FREE(gNodeCount);
    SUPERLU_FREE(gNodeLists);
    free_treelist(nsupers, treeList);

#if ( DEBUGlevel>=1 )
    CHECK_MALLOC (iam, "Exit sinitTrf3Dpartition_allgrid()");
#endif
    return trf3Dpartition;
} /* sinitTrf3Dpartition_allgrid */
#endif 

#if 0
/* This routine is called by all 3D processes, in driver pdgssvx3d(). */
strf3Dpartition_t* sinitTrf3Dpartition(int_t nsupers,
				      superlu_dist_options_t *options,
				      sLUstruct_t *LUstruct, gridinfo3d_t * grid3d
				      )
{
    gridinfo_t* grid = &(grid3d->grid2d);
    int iam = grid3d->iam;
    int_t *xsup = LUstruct->Glu_persist->xsup;

#if ( DEBUGlevel>=1 )
    CHECK_MALLOC (iam, "Enter sinitTrf3Dpartition()");
#endif
    int_t* perm_c_supno = getPerm_c_supno(nsupers, options,
                                         LUstruct->etree,
    	   		                 LUstruct->Glu_persist,
		                         LUstruct->Llu->Lrowind_bc_ptr,
					 LUstruct->Llu->Ufstnz_br_ptr, grid);
    int_t* iperm_c_supno = getFactIperm(perm_c_supno, nsupers);

    // calculating tree factorization
    int_t *setree = supernodal_etree(nsupers, LUstruct->etree, LUstruct->Glu_persist->supno, xsup);
    treeList_t* treeList = setree2list(nsupers, setree );

    /*update treelist with weight and depth*/
    getSCUweight(nsupers, treeList, xsup,
		  LUstruct->Llu->Lrowind_bc_ptr, LUstruct->Llu->Ufstnz_br_ptr,
		  grid3d);

    calcTreeWeight(nsupers, setree, treeList, xsup);

    gEtreeInfo_t gEtreeInfo;
    gEtreeInfo.setree = setree;
    gEtreeInfo.numChildLeft = (int_t* ) SUPERLU_MALLOC(sizeof(int_t) * nsupers);
    for (int_t i = 0; i < nsupers; ++i)
    {
        /* code */
        gEtreeInfo.numChildLeft[i] = treeList[i].numChild;
    }

    int maxLvl = log2i(grid3d->zscp.Np) + 1; /* Levels for Pz process layer */
    sForest_t**  sForests = getForests( maxLvl, nsupers, setree, treeList);
    /*indexes of trees for my process grid in gNodeList size(maxLvl)*/
    int_t* myTreeIdxs = getGridTrees(grid3d);
    int_t* myZeroTrIdxs = getReplicatedTrees(grid3d);
    int_t*  gNodeCount = getNodeCountsFr(maxLvl, sForests);
    int_t** gNodeLists = getNodeListFr(maxLvl, sForests); // reuse NodeLists stored in sForests[]

    sinit3DLUstructForest(myTreeIdxs, myZeroTrIdxs,
                         sForests, LUstruct, grid3d);
    // printf("iam3d %5d, gNodeCount[0] %5d, gNodeCount[1] %5d, gNodeCount[2] %5d\n",grid3d->iam, gNodeCount[0],gNodeCount[1],gNodeCount[2]);
    // printf("iam3d %5d, myTreeIdxs[0] %5d, myZeroTrIdxs[0] %5d\n",grid3d->iam, myTreeIdxs[0],myZeroTrIdxs[0]);
    // printf("iam3d %5d, sForests[0]->nodeList[0] %5d, sForests[1]->nodeList[0] %5d,sForests[2]->nodeList[0] %5d\n",grid3d->iam, sForests[0]->nodeList[0], sForests[1]->nodeList[0],sForests[2]->nodeList[0]);
    // printf("iam3d %5d, myTreeIdxs[0] %5d, myZeroTrIdxs[0] %5d, myTreeIdxs[1] %5d, myZeroTrIdxs[1] %5d, myTreeIdxs[2] %5d, myZeroTrIdxs[2] %5d, myTreeIdxs[3] %5d, myZeroTrIdxs[3] %5d\n",grid3d->iam, myTreeIdxs[0],myZeroTrIdxs[0],myTreeIdxs[1],myZeroTrIdxs[1],myTreeIdxs[2],myZeroTrIdxs[2],myTreeIdxs[3],myZeroTrIdxs[3]);



    int_t* myNodeCount = getMyNodeCountsFr(maxLvl, myTreeIdxs, sForests);
    int_t** treePerm = getTreePermFr( myTreeIdxs, sForests, grid3d);

    sLUValSubBuf_t *LUvsb = SUPERLU_MALLOC(sizeof(sLUValSubBuf_t));
    sLluBufInit(LUvsb, LUstruct);

    int_t* supernode2treeMap = SUPERLU_MALLOC(nsupers*sizeof(int_t));
    int_t numForests = (1 << maxLvl) - 1;
    for (int_t Fr = 0; Fr < numForests; ++Fr)
    {
        /* code */
        for (int_t nd = 0; nd < gNodeCount[Fr]; ++nd)
        {
            /* code */
            supernode2treeMap[gNodeLists[Fr][nd]]=Fr;
        }
    }
    int* supernodeMask = SUPERLU_MALLOC(nsupers*sizeof(int));
    for (int ii = 0; ii < nsupers; ++ii)
        supernodeMask[ii]=0;
    for (int lvl = 0; lvl < maxLvl; ++lvl)
    {
        // printf("lvl %5d myNodeCount[lvl] %5d\n",lvl,myNodeCount[lvl]);
        for (int nd = 0; nd < myNodeCount[lvl]; ++nd)
        {
            supernodeMask[treePerm[lvl][nd]]=1;
        }
    }


    /* Sherry 2/17/23
       Compute buffer sizes needed for diagonal LU blocks and C matrices in GEMM. */

    iam = grid->iam;  /* 'grid' is 2D grid */
    int k, k0, k_st, k_end, offset, nsupc, krow, kcol;
    int myrow = MYROW (iam, grid);
    int mycol = MYCOL (iam, grid);

#if 0
    int krow = PROW (k, grid);
    int kcol = PCOL (k, grid);
    int_t** Lrowind_bc_ptr = Llu->Lrowind_bc_ptr;

    int_t** Ufstnz_br_ptr = Llu->Ufstnz_br_ptr;
#endif

    int mxLeafNode = 0; // Yang: only need to check the leaf level of topoInfo as the factorization proceeds level by level
    for (int ilvl = 0; ilvl < maxLvl; ++ilvl) {
        if (sForests[myTreeIdxs[ilvl]] && sForests[myTreeIdxs[ilvl]]->topoInfo.eTreeTopLims[1] > mxLeafNode )
            mxLeafNode    = sForests[myTreeIdxs[ilvl]]->topoInfo.eTreeTopLims[1];
    }

    // Yang: use ldts to track the maximum needed buffer sizes per node of topoInfo
    //int *ldts = (int*) SUPERLU_MALLOC(mxLeafNode*sizeof(int));
    //for (int i = 0; i < mxLeafNode; ++i) {  //????????
    //ldts[i]=1;
    //}
    int *ldts = int32Calloc_dist(mxLeafNode);

    for (int ilvl = 0; ilvl < maxLvl; ++ilvl) {  /* Loop through the Pz tree levels */
        int treeId = myTreeIdxs[ilvl];
        sForest_t* sforest = sForests[treeId];
        if (sforest){
            int_t *perm_node = sforest->nodeList ; /* permuted list, in order of factorization */
	    int maxTopoLevel = sforest->topoInfo.numLvl;/* number of levels at each outer-tree node */
            for (int topoLvl = 0; topoLvl < maxTopoLevel; ++topoLvl)
            {
                /* code */
                k_st = sforest->topoInfo.eTreeTopLims[topoLvl];
                k_end = sforest->topoInfo.eTreeTopLims[topoLvl + 1];
		//printf("\t..topoLvl %d, k_st %d, k_end %d\n", topoLvl, k_st, k_end);

                for (int k0 = k_st; k0 < k_end; ++k0)
                {
                    offset = k0 - k_st;
                    k = perm_node[k0];
                    nsupc = SuperSize (k);
                    krow = PROW (k, grid);
                    kcol = PCOL (k, grid);
                    if ( myrow == krow || mycol == kcol )  /* diagonal process */
                    {
		        ldts[offset] = SUPERLU_MAX(ldts[offset], nsupc);
                    }
#if 0 /* GPU gemm buffers can only be set on GPU side, because here we only know
	 the size of U data structure on CPU.  It is different on GPU */
                    if ( mycol == kcol ) { /* processes owning L panel */

		    }
                    if ( myrow == krow )
			gemmCsizes[offset] = SUPERLU_MAX(ldts[offset], ???);
#endif
                }
            }
        }
    }

    //PrintInt10("inittrf3Dpartition: ldts", mxLeafNode, ldts);
    strf3Dpartition_t*  trf3Dpartition = SUPERLU_MALLOC(sizeof(strf3Dpartition_t));

    trf3Dpartition->gEtreeInfo = gEtreeInfo;
    trf3Dpartition->iperm_c_supno = iperm_c_supno;
    trf3Dpartition->myNodeCount = myNodeCount;
    trf3Dpartition->myTreeIdxs = myTreeIdxs;
    trf3Dpartition->myZeroTrIdxs = myZeroTrIdxs;
    trf3Dpartition->sForests = sForests;
    trf3Dpartition->treePerm = treePerm;
    trf3Dpartition->maxLvl = maxLvl;
    trf3Dpartition->LUvsb = LUvsb;
    trf3Dpartition->supernode2treeMap = supernode2treeMap;
    trf3Dpartition->supernodeMask = supernodeMask;
    trf3Dpartition->mxLeafNode = mxLeafNode;  // Sherry added these 3
    trf3Dpartition->diagDims = ldts;
    //trf3Dpartition->gemmCsizes = gemmCsizes;

    // Sherry added
    // Deallocate storage
    SUPERLU_FREE(gNodeCount);
    SUPERLU_FREE(gNodeLists);
    SUPERLU_FREE(perm_c_supno);
    free_treelist(nsupers, treeList);

#if ( DEBUGlevel>=1 )
    CHECK_MALLOC (iam, "Exit sinitTrf3Dpartition()");
#endif
    return trf3Dpartition;
} /* end sinitTrf3Dpartition */
#endif

/* Free memory allocated for trf3Dpartition structure. Sherry added this routine */
void sDestroy_trf3Dpartition(strf3Dpartition_t *trf3Dpartition)
{
    if(trf3Dpartition!=NULL){
    int i;
    SUPERLU_FREE(trf3Dpartition->gEtreeInfo.setree);
    SUPERLU_FREE(trf3Dpartition->gEtreeInfo.numChildLeft);
    SUPERLU_FREE(trf3Dpartition->iperm_c_supno);
    SUPERLU_FREE(trf3Dpartition->myNodeCount);
    SUPERLU_FREE(trf3Dpartition->myTreeIdxs);
    SUPERLU_FREE(trf3Dpartition->myZeroTrIdxs);
    SUPERLU_FREE(trf3Dpartition->diagDims);
    SUPERLU_FREE(trf3Dpartition->treePerm); // double pointer pointing to sForests->nodeList

    int_t maxLvl = trf3Dpartition->maxLvl;
    int_t numForests = (1 << maxLvl) - 1;
    sForest_t** sForests = trf3Dpartition->sForests;
    for (i = 0; i < numForests; ++i) {
	if ( sForests[i] ) {
	    SUPERLU_FREE(sForests[i]->nodeList);
	    SUPERLU_FREE((sForests[i]->topoInfo).eTreeTopLims);
	    SUPERLU_FREE((sForests[i]->topoInfo).myIperm);
	    SUPERLU_FREE(sForests[i]); // Sherry added
	}
    }
    SUPERLU_FREE(trf3Dpartition->sForests); // double pointer
    SUPERLU_FREE(trf3Dpartition->supernode2treeMap);
    SUPERLU_FREE(trf3Dpartition->supernodeMask);
    SUPERLU_FREE(trf3Dpartition->superGridMap);

    SUPERLU_FREE((trf3Dpartition->LUvsb)->Lsub_buf);
    SUPERLU_FREE((trf3Dpartition->LUvsb)->Lval_buf);
    SUPERLU_FREE((trf3Dpartition->LUvsb)->Usub_buf);
    SUPERLU_FREE((trf3Dpartition->LUvsb)->Uval_buf);
    SUPERLU_FREE(trf3Dpartition->LUvsb); // Sherry: check this ...

    SUPERLU_FREE(trf3Dpartition);
    }
    trf3Dpartition=NULL;

}


#if 0  //**** Sherry: following two routines are old, the new ones are in util.c
int_t num_full_cols_U(int_t kk,  int_t **Ufstnz_br_ptr, int_t *xsup,
                      gridinfo_t *grid, int_t *perm_u)
{
    int_t lk = LBi (kk, grid);
    int_t *usub = Ufstnz_br_ptr[lk];

    if (usub == NULL)
    {
        /* code */
        return 0;
    }
    int_t iukp = BR_HEADER;   /* Skip header; Pointer to index[] of U(k,:) */
    int_t rukp = 0;           /* Pointer to nzval[] of U(k,:) */
    int_t nub = usub[0];      /* Number of blocks in the block row U(k,:) */

    int_t klst = FstBlockC (kk + 1);
    int_t iukp0 = iukp;
    int_t rukp0 = rukp;
    int_t jb, ljb;
    int_t nsupc;
    int_t temp_ncols = 0;
    int_t segsize;

    temp_ncols = 0;

    for (int_t j = 0; j < nub; ++j)
    {
        arrive_at_ublock(
            j, &iukp, &rukp, &jb, &ljb, &nsupc,
            iukp0, rukp0, usub, perm_u, xsup, grid
        );

        for (int_t jj = iukp; jj < iukp + nsupc; ++jj)
        {
            segsize = klst - usub[jj];
            if ( segsize ) ++temp_ncols;
        }
    }
    return temp_ncols;
}

// Sherry: this is old; new version is in util.c
int_t estimate_bigu_size( int_t nsupers, int_t ldt, int_t**Ufstnz_br_ptr,
                          Glu_persist_t *Glu_persist,  gridinfo_t* grid, int_t* perm_u)
{

    int_t iam = grid->iam;

    int_t Pr = grid->nprow;
    int_t myrow = MYROW (iam, grid);

    int_t* xsup = Glu_persist->xsup;

    int ncols = 0;
    int_t ldu = 0;

    /*initilize perm_u*/
    for (int i = 0; i < nsupers; ++i)
    {
        perm_u[i] = i;
    }

    for (int lk = myrow; lk < nsupers; lk += Pr )
    {
        ncols = SUPERLU_MAX(ncols, num_full_cols_U(lk, Ufstnz_br_ptr,
						   xsup, grid, perm_u, &ldu));
    }

    int_t max_ncols = 0;

    MPI_Allreduce(&ncols, &max_ncols, 1, mpi_int_t, MPI_MAX, grid->cscp.comm);

    printf("max_ncols =%d, bigu_size=%ld\n", (int) max_ncols, (long long) ldt * max_ncols);
    return ldt * max_ncols;
} /* old estimate_bigu_size. New one is in util.c */
#endif /**** end old ones ****/


