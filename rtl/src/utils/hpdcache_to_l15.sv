/*
 *  Copyright 2023 CEA*
 *  *Commissariat a l'Energie Atomique et aux Energies Alternatives (CEA)
 *
 *  SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 *  Licensed under the Solderpad Hardware License v 2.1 (the “License”); you
 *  may not use this file except in compliance with the License, or, at your
 *  option, the Apache License version 2.0. You may obtain a copy of the
 *  License at
 *
 *  https://solderpad.org/licenses/SHL-2.1/
 *
 *  Unless required by applicable law or agreed to in writing, any work
 *  distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
 *  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 *  License for the specific language governing permissions and limitations
 *  under the License.
 */
/*
 *  Authors       : Noelia Oliete, Cesar Fuguet
 *  Creation Date : June, 2023
 *  Description   : L1.5, L1I and HPDC adapter
 *  History       :
 */
module hpdcache_to_l15 import hpdcache_pkg::*; import wt_cache_pkg::*;
//  Parameters
//  {{{
#(
    parameter hpdcache_uint    N = 0,
    parameter hpdcache_uint    AdapterInvalFifoDepth = 5,
    parameter bit              SwapEndianess = 1,
    parameter hpdcache_uint    HPDcacheMemDataWidth = 128,

    parameter type hpdcache_mem_req_t = logic,
    parameter type hpdcache_mem_req_w_t = logic,
    parameter type hpdcache_mem_id_t = logic,
    parameter type hpdcache_mem_addr_t = logic,
    parameter type hpdcache_mem_resp_t = logic,
    parameter type req_portid_t = logic
)
//  }}}

//  Ports
//  {{{
(
    input   logic                          clk_i,
    input   logic                          rst_ni,

    output  logic                          req_ready_o,
    input   logic                          req_valid_i,
    input   req_portid_t                   req_pid_i,
    input   hpdcache_mem_req_t             req_i,
    input   hpdcache_mem_req_w_t           req_data_i,
    input   logic                          req_index_i [N-1:0],

    input   logic                          resp_ready_i,
    output  logic                          resp_valid_o,
    output  req_portid_t                   resp_pid_o,
    output  hpdcache_mem_resp_t            resp_o,

    input   logic                          hpdc_fifo_inval_ready_i,
    output  logic                          hpdc_fifo_inval_valid_o,
    output  hpdcache_pkg::hpdcache_req_t   hpdc_fifo_inval_o,

    output  logic                          sc_backoff_over_o,

    output  wt_cache_pkg::l15_req_t        l15_req_o,

    input   wt_cache_pkg::l15_rtrn_t       l15_rtrn_i
    
);
//  }}}

    // Internal functions
    // {{{
    // Swap endianess in a 8B word
    function automatic logic[7:0] swendian8B(input logic[7:0] in);
        automatic logic[7:0] out;
        for(int k=0; k<8;k++)begin
            out[k] = in[7-k];
        end
        return out;
    endfunction
    // }}}
    
     // Internal types
     // {{{ 
    typedef enum {
        FREE_T0_T1,
        FREE_T0,
        FREE_T1,
        LOCKED_T0_T1
    } thread_id_fsm_t;

    // L15_TIDs entry table to save the HPDC threadids and portids
    typedef hpdcache_mem_id_t [1:0] hpdc_thid_l15et_t;
    typedef req_portid_t      [1:0] hpdc_pid_l15et_t;

    // }}}

    // Declaration of internal registers/signals
    // {{{

    // Request type
    logic                                       req_is_ifill;
    logic                                       req_is_read;
    logic                                       req_is_write;
    logic                                       req_is_unc_read;
    logic                                       req_is_unc_write;
    logic                                       req_is_atomic;
    ariane_pkg::amo_t                           req_amo_op_type;
    // Data & Byte mask sended by the request
    logic [HPDcacheMemDataWidth-1:0]            req_wdata;
    logic [HPDcacheMemDataWidth/8-1:0]          req_wbe;
    // FSM State 
    thread_id_fsm_t                             th_state_q, th_state_d;
    // HPDC Req ID
    hpdc_thid_l15et_t                           hpdc_tid_q, hpdc_tid_d;
    // HPDC Req Port ID
    hpdc_pid_l15et_t                            hpdc_pid_q, hpdc_pid_d;
    // L1.5 Req Thread ID 
    logic [wt_cache_pkg::L15_TID_WIDTH-1:0]     req_thid;
    // HPDC Resp ID
    hpdcache_mem_id_t                           resp_tid;
    // HPDC Port ID
    req_portid_t                                resp_pid;
    // Size of the unc. store request. Its compulsory to replicate the data of the request according to its size. 
    hpdcache_pkg::hpdcache_mem_size_t           req_unc_st_size;
    logic [HPDcacheMemDataWidth/8-1:0]          req_unc_st_offset;
    logic [$clog2(HPDcacheMemDataWidth/8)-1:0]  first_one_pos,num_ones;
    // Invalidations
    logic                                       mem_inval_icache_valid;
    logic                                       mem_inval_dcache_valid;
    logic                                       mem_only_inval;
    logic                                       hpdc_fifo_inval_wok;
    // LR/SC Back-off mechanism
    logic                                       sc_pass;
    logic                                       sc_fail;
    // }}}


    // Request
    // {{{
                                                // Determines that the L1.5 can receive a request if L1.5 is ready and there is a thid free
    assign req_ready_o                        = l15_rtrn_i.l15_ack & (th_state_q!=LOCKED_T0_T1);
                                                // Determines that a request is valid if there is a thid free
    assign l15_req_o.l15_val                  = req_valid_i & (th_state_q!=LOCKED_T0_T1), 
                                                // Determines if we can hold the coming response
           l15_req_o.l15_req_ack              = (mem_inval_dcache_valid) ? (mem_only_inval) ? l15_rtrn_i.l15_val & hpdc_fifo_inval_wok :                // DCACHE Invalidation
                                                                                              l15_rtrn_i.l15_val & hpdc_fifo_inval_wok & resp_ready_i : // Response + DCACHE Invalidation
                                                                            l15_rtrn_i.l15_val & resp_ready_i,                                          // Response/ICACHE Invalidation
                                                // Request type
           l15_req_o.l15_rqtype               = (req_is_ifill) ? L15_IMISS_RQ :
                                                (req_is_read  || req_is_unc_read)  ? L15_LOAD_RQ : 
                                                (req_is_write || req_is_unc_write) ? L15_STORE_RQ : L15_ATOMIC_RQ,
           l15_req_o.l15_nc                   = ~req_i.mem_req_cacheable,
                                                // IMiss Unch: 4B Cach: 32B cacheline; Load/Store/AMO Max 16B cacheline (other possible sizes: 1,2,4,8B)
           l15_req_o.l15_size                 = (req_is_ifill)                  ? ((req_i.mem_req_cacheable) ? 3'b111 : 3'b010) : // IMiss     
                                                (req_is_unc_write)              ? req_unc_st_size :                               // Unc. Store
                                                (req_i.mem_req_size == 3'b100)  ? 3'b111 : req_i.mem_req_size,                    // Load & Unc. Load / Store / AMO
           l15_req_o.l15_threadid             = req_thid, 
           l15_req_o.l15_address              = req_i.mem_req_addr,
                                                // Swap Endiannes and replicate transfers shorter than a dword for Store/AMO requests
           l15_req_o.l15_data                 = (SwapEndianess) ? (req_is_unc_write) ?  swendian64(repData64(req_wdata[63:0],req_unc_st_offset,req_unc_st_size[1:0]))  :
                                                                                        swendian64(req_wdata[63:0]) : 
                                                                  (req_is_unc_write) ?  repData64(req_wdata[63:0],req_unc_st_offset,req_unc_st_size[1:0]) :
                                                                                        req_wdata[63:0],
           l15_req_o.l15_data_next_entry      = '0, // unused in Ariane (only used for CAS atomic requests)
           l15_req_o.l15_csm_data             = '0, // unused in Ariane (only used for coherence domain restriction features)
           l15_req_o.l15_amo_op               = req_amo_op_type,
           l15_req_o.l15_prefetch             = '0, // unused in openpiton
           l15_req_o.l15_invalidate_cacheline = '0, // unused by Ariane as L1 has no ECC at the moment
           l15_req_o.l15_blockstore           = '0, // unused in openpiton
           l15_req_o.l15_blockinitstore       = '0, // unused in openpiton
           l15_req_o.l15_l1rplway             = '0, // Not used for this adapter
           l15_req_o.l15_be                   = swendian8B(req_wbe[0 +: 8] | req_wbe[HPDcacheMemDataWidth/8-1 -: 8]); 

    // Type of request based on the request mux index port (req_index_i: 0->IMISS, 1->Read 2-> Write 3-> Un.Read 4-> Un. Write)
    assign req_is_ifill                       = req_index_i[0],
           req_is_read                        = req_index_i[1] & (req_i.mem_req_command==hpdcache_pkg::HPDCACHE_MEM_READ),  // Load 
           req_is_write                       = req_index_i[2] & (req_i.mem_req_command==hpdcache_pkg::HPDCACHE_MEM_WRITE), // Store & Unc. Store 
           req_is_unc_read                    = req_index_i[3] & (req_i.mem_req_command==hpdcache_pkg::HPDCACHE_MEM_READ),  // Unc. Load  
           req_is_unc_write                   = req_index_i[4] & (req_i.mem_req_command==hpdcache_pkg::HPDCACHE_MEM_WRITE), // Unc. Store 
           req_is_atomic                      = req_index_i[4] & (req_i.mem_req_command==hpdcache_pkg::HPDCACHE_MEM_ATOMIC);// AMO

    // Data sended by the request
    // If the request is a AMO_CLR, its translated as a AMO_AND. Therefore, the data sended has to be inverted
    assign req_wdata                          = (req_is_atomic & req_i.mem_req_atomic==HPDCACHE_MEM_ATOMIC_CLR) ? ~req_data_i.mem_req_w_data : req_data_i.mem_req_w_data,
           req_wbe                            = req_data_i.mem_req_w_be[HPDcacheMemDataWidth/8-1:0]; 
    
    // }}}


    // Response
    // {{{
                                                // Determines if the response received is valid for the response demux
    assign resp_valid_o                       = (mem_inval_dcache_valid) ? (mem_only_inval) ? '0 :                                       // DCACHE Invalidation
                                                                                              l15_rtrn_i.l15_val & hpdc_fifo_inval_wok : // Response + DCACHE Invalidation
                                                                                              l15_rtrn_i.l15_val,                        // Response/ICACHE Invalidation
                                                // ICACHE Invalidations demux port 0 otherwise saved port id
           resp_pid_o                         = (mem_only_inval & mem_inval_icache_valid) ? '0 : 
                                                (l15_rtrn_i.l15_returntype==L15_CPX_RESTYPE_ATOMIC_RES) ? 3'b101 : resp_pid;
                                                
    assign resp_o.mem_resp_error              = (l15_rtrn_i.l15_returntype==L15_ERR_RET) ? HPDCACHE_MEM_RESP_NOK : HPDCACHE_MEM_RESP_OK, // Should be always HPDCACHE_MEM_RESP_OK, unused in openpiton
           resp_o.mem_resp_id                 = resp_tid,
           resp_o.mem_resp_r_last             = '1,                                                                                      // OpenPiton sends the entire data in 1 cycle
           resp_o.mem_resp_w_is_atomic        = sc_pass,               
           resp_o.mem_resp_r_data             = (SwapEndianess) ? {swendian64(l15_rtrn_i.l15_data_3),
                                                                    swendian64(l15_rtrn_i.l15_data_2),
                                                                    swendian64(l15_rtrn_i.l15_data_1),
                                                                    swendian64(l15_rtrn_i.l15_data_0)} :
                                                                  {l15_rtrn_i.l15_data_3,
                                                                    l15_rtrn_i.l15_data_2,
                                                                    l15_rtrn_i.l15_data_1,
                                                                    l15_rtrn_i.l15_data_0};

    // Invalidation request translated as a CMO 
    assign resp_o.mem_inval_icache_valid      = mem_inval_icache_valid,
           resp_o.mem_inval_dcache_valid      = mem_inval_dcache_valid,
           resp_o.mem_inval.addr              = mem_inval_icache_valid ? { l15_rtrn_i.l15_transducer_address[ariane_pkg::ICACHE_INDEX_WIDTH-1:4], 4'b0000} : 
                                                                         { hpdcache_req_addr_t'(l15_rtrn_i.l15_transducer_address)},
           resp_o.mem_inval.need_rsp          = 1'b0,
           resp_o.mem_inval.uncacheable       = 1'b0,
           resp_o.mem_inval.sid               = '0,
           resp_o.mem_inval.tid               = '0,
           resp_o.mem_inval.wdata             = '0,      
           resp_o.mem_inval.be                = '0,
           resp_o.mem_inval.op                = HPDCACHE_REQ_CMO,
           resp_o.mem_inval.size              = HPDCACHE_REQ_CMO_INVAL_NLINE;

    assign mem_inval_icache_valid             = (l15_rtrn_i.l15_inval_icache_inval || l15_rtrn_i.l15_inval_icache_all_way), 
           mem_inval_dcache_valid             = (l15_rtrn_i.l15_inval_dcache_inval || l15_rtrn_i.l15_inval_dcache_all_way),
           mem_only_inval                     = l15_rtrn_i.l15_returntype==L15_EVICT_REQ;
    // }}}


    // FSM to control the access to L1.5. OpenPiton doesn't support more than 2 requests -> 2 threads
    // {{{
    always_comb
    begin: thread_id_fsm_comb
        th_state_d = th_state_q;
        hpdc_tid_d = hpdc_tid_q;
        hpdc_pid_d = hpdc_pid_q;
        unique case (th_state_q)
            // Both available threads are free
            FREE_T0_T1: begin
                // Request valid and L1.5 can receive -> Send Request 
                req_thid = 1'b0;                        // Thid used: 0
                if (req_valid_i && l15_rtrn_i.l15_ack) begin
                    hpdc_tid_d[0] = req_i.mem_req_id;   // Save the real Thid
                    hpdc_pid_d[0]  = req_pid_i;         // Save the port id
                    th_state_d     = FREE_T1;
                end
            end
            // Only Th0 is free
            FREE_T0: begin
                req_thid = 1'b0;                        // Thid used: 0
                resp_tid = hpdc_tid_q[l15_rtrn_i.l15_threadid];
                resp_pid = hpdc_pid_q[l15_rtrn_i.l15_threadid];
                // Request and Response comes at the same time
                if ((req_valid_i && l15_rtrn_i.l15_ack) && (resp_ready_i && l15_rtrn_i.l15_val && ~mem_only_inval)) begin
                    // Request
                    hpdc_tid_d[0] = req_i.mem_req_id;   // Save the real Thid
                    hpdc_pid_d[0] = req_pid_i;
                    //Th1 used, Th0 free
                    th_state_d = FREE_T1;
                end else begin 
                    // Response valid and L1D/I can receive -> Receive Response   
                    if (resp_ready_i && l15_rtrn_i.l15_val && ~mem_only_inval) begin
                        th_state_d = FREE_T0_T1;
                    // Request valid and L1.5 can receive -> Send Request
                    end else if (req_valid_i && l15_rtrn_i.l15_ack) begin           
                        hpdc_tid_d[0] = req_i.mem_req_id;   // Save the real Thid
                        hpdc_pid_d[0]  = req_pid_i;
                        th_state_d = LOCKED_T0_T1;
                    end
                end 
            end
            // Only Th1 is free
            FREE_T1: begin   
                req_thid = 1'b1;                        // Thid used: 1
                resp_tid = hpdc_tid_q[l15_rtrn_i.l15_threadid];
                resp_pid = hpdc_pid_q[l15_rtrn_i.l15_threadid];
                // Request and Response comes at the same time 
                if ((req_valid_i && l15_rtrn_i.l15_ack) && (resp_ready_i && l15_rtrn_i.l15_val && ~mem_only_inval)) begin
                    //Request
                    hpdc_tid_d[1] = req_i.mem_req_id;   // Save the real Thid
                    hpdc_pid_d[1] = req_pid_i;
                    //Th0 used, Th1 free
                    th_state_d = FREE_T0;
                end else begin 
                    // Response valid and L1D/I can receive -> Receive Response
                    if (resp_ready_i && l15_rtrn_i.l15_val && ~mem_only_inval) begin
                        resp_tid = hpdc_tid_q[l15_rtrn_i.l15_threadid];
                        resp_pid = hpdc_pid_q[l15_rtrn_i.l15_threadid];
                        th_state_d = FREE_T0_T1;
                    // Request valid and L1.5 can receive -> Send Request
                    end else if (req_valid_i && l15_rtrn_i.l15_ack) begin
                        hpdc_tid_d[1] = req_i.mem_req_id;   // Save the real Thid
                        hpdc_pid_d[1]  = req_pid_i;
                        th_state_d = LOCKED_T0_T1;
                    end
                end
            end
            // No Threadids available
            LOCKED_T0_T1: begin
                // Response valid and L1D/I can receive -> Receive Request
                resp_tid = hpdc_tid_q[l15_rtrn_i.l15_threadid];
                resp_pid = hpdc_pid_q[l15_rtrn_i.l15_threadid];
                if (resp_ready_i && l15_rtrn_i.l15_val && ~mem_only_inval) begin
                    th_state_d = (l15_rtrn_i.l15_threadid) ? FREE_T1 : FREE_T0;
                end
            end
        endcase
    end
   

    
    always_ff @(posedge clk_i or negedge rst_ni)
    begin: thread_id_fsm_ff
     if (!rst_ni) begin
            th_state_q     <= FREE_T0_T1;
            hpdc_tid_q[0]  <= '0;
            hpdc_tid_q[1]  <= '0; 
            hpdc_pid_q[0]  <= '0;
            hpdc_pid_q[1]  <= '0;
        end else begin
            th_state_q     <= th_state_d;
            hpdc_tid_q[0]  <= hpdc_tid_d[0];
            hpdc_tid_q[1]  <= hpdc_tid_d[1]; 
            hpdc_pid_q[0]  <= hpdc_pid_d[0];
            hpdc_pid_q[1]  <= hpdc_pid_d[1];
        end
    end

     // }}}

    // Combinational logic to obtain the store size for data replication
    // {{{

    always_comb
    begin: lzc_comb
        first_one_pos = '0;
        for (int unsigned i = int'(HPDcacheMemDataWidth/8); i > 0; i--) begin
            if (req_wbe[i-1]) begin
                first_one_pos = i-1;
                break;
            end
        end
    end

    assign num_ones =  $countones(req_wbe);

    always_comb 
    begin:rst_size_comb
        unique case (num_ones)
            4'b0001: begin
                req_unc_st_size   = '0;      //1B
                req_unc_st_offset = first_one_pos[2:0];
            end
            4'b0010: begin
                req_unc_st_size   = 3'b001;  //2B
                req_unc_st_offset = (first_one_pos[2:0]-1'b1);
            end
            4'b0100: begin 
                req_unc_st_size   = 3'b010;  //4B
                req_unc_st_offset = (first_one_pos[2:0]-2'b11);          
            end 
            4'b1000: begin
                 req_unc_st_size   = 3'b011; //8B
                 req_unc_st_offset = '0;
            end
            default: begin 
                req_unc_st_size   = 3'b111;  //16B
                req_unc_st_offset = '0;
            end
        endcase
    end
    // }}}

    // AMO support
    // {{{
        // Translator of the atomic operation request type (HPDC->OpenPiton)
        // {{{
    always_comb 
    begin:atomic_req_op_type_comb
        unique case (req_i.mem_req_atomic)
            HPDCACHE_MEM_ATOMIC_ADD:  req_amo_op_type = ariane_pkg::AMO_ADD;
            HPDCACHE_MEM_ATOMIC_CLR:  req_amo_op_type = ariane_pkg::AMO_AND;
            HPDCACHE_MEM_ATOMIC_SET:  req_amo_op_type = ariane_pkg::AMO_OR;
            HPDCACHE_MEM_ATOMIC_EOR:  req_amo_op_type = ariane_pkg::AMO_XOR;
            HPDCACHE_MEM_ATOMIC_SMAX: req_amo_op_type = ariane_pkg::AMO_MAX;
            HPDCACHE_MEM_ATOMIC_SMIN: req_amo_op_type = ariane_pkg::AMO_MIN;
            HPDCACHE_MEM_ATOMIC_UMAX: req_amo_op_type = ariane_pkg::AMO_MAXU;
            HPDCACHE_MEM_ATOMIC_UMIN: req_amo_op_type = ariane_pkg::AMO_MINU;
            HPDCACHE_MEM_ATOMIC_SWAP: req_amo_op_type = ariane_pkg::AMO_SWAP;
            HPDCACHE_MEM_ATOMIC_LDEX: req_amo_op_type = ariane_pkg::AMO_LR;
            HPDCACHE_MEM_ATOMIC_STEX: req_amo_op_type = ariane_pkg::AMO_SC;
            default:                  req_amo_op_type = ariane_pkg::AMO_NONE;
        endcase
    end
        // }}}

        // Back-off mechanism for LR/SC completion guarantee
        // {{{
    exp_backoff #(
        .Seed(3),
        .MaxExp(16)
    ) i_exp_backoff (
        .clk_i,
        .rst_ni,
        .set_i     ( sc_fail         ),
        .clr_i     ( sc_pass         ),
        .is_zero_o ( sc_backoff_over_o )
    );

    assign sc_pass = (l15_rtrn_i.l15_returntype!=L15_CPX_RESTYPE_ATOMIC_RES) ? 1'b0 : 
                     (|l15_rtrn_i.l15_data_0) ? 1'b0 : 1'b1;       // AMO_SC pass if data=0

    assign sc_fail = (l15_rtrn_i.l15_returntype!=L15_CPX_RESTYPE_ATOMIC_RES) ? 1'b0 : 
                     (|l15_rtrn_i.l15_data_0) ? 1'b1 : 1'b0;       // AMO_SC fail if data!=0
        // }}}
    // }}}

    // FIFO to keep invalidation requests until they are attended by the HPDC
    // {{{
    hpdcache_fifo_reg #(
            .FIFO_DEPTH  (AdapterInvalFifoDepth),
            .fifo_data_t (hpdcache_pkg::hpdcache_req_t)
    ) i_dcache_inval_fifo (
            .clk_i,
            .rst_ni,
            // Valid input if its an DCACHE invalidation and its a valid response
            .w_i    (resp_o.mem_inval_dcache_valid & l15_rtrn_i.l15_val),
            // Space available
            .wok_o  (hpdc_fifo_inval_wok), 
            .wdata_i(resp_o.mem_inval),
            // HPDC is ready to process an invalidation 
            .r_i    (hpdc_fifo_inval_ready_i), 
            // Inval pending
            .rok_o  (hpdc_fifo_inval_valid_o),
            .rdata_o(hpdc_fifo_inval_o)
    );
    // }}}
endmodule
