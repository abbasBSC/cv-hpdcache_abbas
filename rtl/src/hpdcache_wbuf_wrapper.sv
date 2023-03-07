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
 *  Authors       : Cesar Fuguet
 *  Creation Date : April, 2021
 *  Description   : HPDcache Write Buffer Wrapper
 *  History       :
 */
/*  This wrapper adapts the send interface of the write buffer to the memory
 *  interface of the cache.
 */
module hpdcache_wbuf_wrapper
import hpdcache_pkg::*;
    //  Ports
    //  {{{
(
    //      Clock and reset signals
    input  wire logic                  clk_i,
    input  wire logic                  rst_ni,

    //      Global control signals
    output wire logic                  empty_o,
    output wire logic                  full_o,
    input  wire logic                  close_all_i,

    //      Configuration signals
    //          Timer threshold
    input  wire wbuf_timecnt_t         cfg_threshold_i,
    //          Reset timer on write
    input  wire logic                  cfg_reset_timecnt_on_write_i,
    //          Sequentialize write-after-write hazards
    input  wire logic                  cfg_sequential_waw_i,

    //      Write interface
    input  wire logic                  write_i,
    output wire logic                  write_ready_o,
    input  wire wbuf_addr_t            write_addr_i,
    input  wire wbuf_data_t            write_data_i,
    input  wire wbuf_be_t              write_be_i,  // byte-enable
    input  wire logic                  write_uc_i,  // uncacheable write

    //      Read hit interface
    input  wire wbuf_addr_t            read_addr_i,
    output wire logic                  read_hit_o,
    input  wire logic                  read_close_hit_i,

    //      Replay hit interface
    input  wire wbuf_addr_t            replay_addr_i,
    input  wire logic                  replay_is_read_i,
    output wire logic                  replay_open_hit_o,
    output wire logic                  replay_closed_hit_o,
    output wire logic                  replay_sent_hit_o,
    output wire logic                  replay_not_ready_o,

    //      Memory interface
    input  wire logic                  mem_req_write_ready_i,
    output wire logic                  mem_req_write_valid_o,
    output wire hpdcache_mem_req_t     mem_req_write_o,

    input  wire logic                  mem_req_write_data_ready_i,
    output wire logic                  mem_req_write_data_valid_o,
    output wire hpdcache_mem_req_w_t   mem_req_write_data_o,

    output wire logic                  mem_resp_write_ready_o,
    input  wire logic                  mem_resp_write_valid_i,
    input  wire hpdcache_mem_resp_w_t  mem_resp_write_i
);
    //  }}}

    //  Internal signals
    //  {{{
    wbuf_addr_t     send_addr;
    wbuf_dir_ptr_t  send_id;
    logic           send_uc;
    wbuf_addr_t     send_data_tag;
    wbuf_data_buf_t send_data;
    wbuf_be_buf_t   send_be;
    wbuf_dir_ptr_t  ack_id;
    logic           ack_error;
    //  }}}

    //  Wrapped write buffer
    //  {{{
    hpdcache_wbuf #(
        .WBUF_DIR_ENTRIES              (HPDCACHE_WBUF_DIR_ENTRIES),
        .WBUF_DATA_ENTRIES             (HPDCACHE_WBUF_DATA_ENTRIES),
        .WBUF_WORD_WIDTH               (HPDCACHE_REQ_DATA_WIDTH),
        .WBUF_WORDS                    (HPDCACHE_WBUF_WORDS),
        .WBUF_PA_WIDTH                 (HPDCACHE_PA_WIDTH),
        .WBUF_TIMECNT_MAX              ((2**HPDCACHE_WBUF_TIMECNT_WIDTH) - 1),
        .WBUF_READ_MATCH_WIDTH         (HPDCACHE_NLINE_WIDTH)
    ) hpdcache_wbuf_i (
        .clk_i,
        .rst_ni,
        .empty_o,
        .full_o,
        .close_all_i,
        .cfg_threshold_i,
        .cfg_reset_timecnt_on_write_i,
        .cfg_sequential_waw_i,
        .write_i,
        .write_ready_o,
        .write_addr_i,
        .write_data_i,
        .write_be_i,
        .write_uc_i,
        .read_addr_i,
        .read_hit_o,
        .read_close_hit_i,
        .replay_addr_i,
        .replay_is_read_i,
        .replay_open_hit_o,
        .replay_closed_hit_o,
        .replay_sent_hit_o,
        .replay_not_ready_o,
        .send_meta_ready_i             (mem_req_write_ready_i),
        .send_meta_valid_o             (mem_req_write_valid_o),
        .send_addr_o                   (send_addr),
        .send_id_o                     (send_id),
        .send_uc_o                     (send_uc),
        .send_data_ready_i             (mem_req_write_data_ready_i),
        .send_data_valid_o             (mem_req_write_data_valid_o),
        .send_data_tag_o               (send_data_tag),
        .send_data_o                   (send_data),
        .send_be_o                     (send_be),
        .ack_i                         (mem_resp_write_valid_i),
        .ack_id_i                      (ack_id),
        .ack_error_i                   (ack_error)
    );
    //  }}}

    //  Memory interface
    //  {{{
    assign  mem_req_write_o.mem_req_addr        = send_addr,
            mem_req_write_o.mem_req_len         = 0,
            mem_req_write_o.mem_req_size        = get_hpdcache_mem_size(HPDCACHE_WBUF_DATA_WIDTH/8),
            mem_req_write_o.mem_req_id          = hpdcache_mem_id_t'(send_id),
            mem_req_write_o.mem_req_command     = HPDCACHE_MEM_WRITE,
            mem_req_write_o.mem_req_atomic      = HPDCACHE_MEM_ATOMIC_ADD,
            mem_req_write_o.mem_req_cacheable   = ~send_uc;

    generate
        localparam int unsigned WBUF_MEM_DATA_RATIO = HPDCACHE_MEM_DATA_WIDTH/HPDCACHE_WBUF_DATA_WIDTH;
        localparam int unsigned WBUF_MEM_DATA_WORD_INDEX_WIDTH = $clog2(WBUF_MEM_DATA_RATIO);

        assign mem_req_write_data_o.mem_req_w_last = 1'b1;

        if (WBUF_MEM_DATA_RATIO > 1)
        begin : wbuf_data_upsizing_gen
            assign mem_req_write_data_o.mem_req_w_data = {WBUF_MEM_DATA_RATIO{send_data}};

            //  demux send BE
            hpdcache_demux #(
                .NOUTPUT     (WBUF_MEM_DATA_RATIO),
                .DATA_WIDTH  (HPDCACHE_WBUF_DATA_WIDTH/8),
                .ONE_HOT_SEL (1'b0)
            ) mem_write_be_demux_i (
                .data_i      (send_be),
                .sel_i       (send_data_tag[0 +: WBUF_MEM_DATA_WORD_INDEX_WIDTH]),
                .data_o      (mem_req_write_data_o.mem_req_w_be)
            );
        end else if (WBUF_MEM_DATA_RATIO == 1)
        begin : wbuf_data_forwarding_gen
            assign mem_req_write_data_o.mem_req_w_data = send_data,
                   mem_req_write_data_o.mem_req_w_be = send_be;
        end

        //  Assertions
        //  {{{
        //  pragma translate_off
        initial assert(WBUF_MEM_DATA_RATIO > 0) else
                $error($sformatf("WBUF: data width of mem interface (%d) shall be g.e. to wbuf data width(%d)",
                                 HPDCACHE_MEM_DATA_WIDTH, HPDCACHE_WBUF_DATA_WIDTH));
        //  pragma translate_on
        //  }}}
    endgenerate

    assign  mem_resp_write_ready_o = 1'b1,
            ack_id                 = mem_resp_write_i.mem_resp_w_id[0 +: HPDCACHE_WBUF_DIR_PTR_WIDTH],
            ack_error              = (mem_resp_write_i.mem_resp_w_error != 0) ? 1'b1 : 1'b0;
    //  }}}

endmodule
