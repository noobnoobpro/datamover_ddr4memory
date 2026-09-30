
-- Standard library and package declarations

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.signals_pkg.all;
use work.signal_recorder_pkg.all;
use work.wishbone_pkg.all;

use work.unittest_pkg.all;
entity tb_data_mover is
end tb_data_mover;

architecture tb of tb_data_mover is

    constant CLK_PERIOD           : time                          := 10 ns;
    constant NUM_SAMPLES          : integer                       := 6;

    signal clk                    : std_logic                     := '0';
    signal rst                    : std_logic                     := '1';

    -- IQ input
    signal iq_data                : std_logic_vector(31 downto 0) := (others => '0');
    signal iq_data_new            : std_logic                     := '0';

    -- CMD AXIS
    signal s_axis_s2mm_cmd_tdata  : std_logic_vector(71 downto 0);
    signal s_axis_s2mm_cmd_tvalid : std_logic;
    signal s_axis_s2mm_cmd_tready : std_logic := '0';

    -- DATA AXIS
    signal s_axis_s2mm_tdata      : std_logic_vector(31 downto 0);
    signal s_axis_s2mm_tkeep      : std_logic_vector(3 downto 0);
    signal s_axis_s2mm_tlast      : std_logic;
    signal s_axis_s2mm_tvalid     : std_logic;
    signal s_axis_s2mm_tready     : std_logic := '0';

    shared variable tst           : t_tst;

begin
    ----
    -- TEST PROCESS
    ----
    stimulus : process
        variable expected_addr : std_logic_vector(31 downto 0);
    begin

        -- GLOBAL RESET

        rst <= '1';
        wait for 3 * CLK_PERIOD;
        rst <= '0';
        wait for 2 * CLK_PERIOD;

        expected_addr := x"80000000";

        ----
        -- TEST 0 : RESET BEHAVIOR
        ----
        tst.init_test("Reset behaviour validation");

        rst <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        Eq('0', s_axis_s2mm_cmd_tvalid, tst);
        Eq('0', s_axis_s2mm_tvalid, tst);

        rst <= '0';
        wait for 2 * CLK_PERIOD;

        Eq('0', s_axis_s2mm_cmd_tvalid, tst);
        Eq('0', s_axis_s2mm_tvalid, tst);

        tst.end_test;
        ----
        -- TEST 1 : Single IQ Sample --> One Command + One Data Beat
        ----
        tst.init_test("Single IQ sample transfer");

        wait until rising_edge(clk);
        iq_data     <= x"ABDABDAB";
        iq_data_new <= '1';

        wait until rising_edge(clk);
        iq_data_new <= '0';
        -- Wait for CMD VALID

        wait until s_axis_s2mm_cmd_tvalid = '1';
        Eq('1', s_axis_s2mm_cmd_tvalid, tst);
        -- Handshake command

        s_axis_s2mm_cmd_tready <= '1';
        wait until rising_edge(clk);
        s_axis_s2mm_cmd_tready <= '0';
        -- Validate command content

        Eq(expected_addr, s_axis_s2mm_cmd_tdata(63 downto 32), tst);
        Eq(x"0004", s_axis_s2mm_cmd_tdata(15 downto 0), tst);
        Eq('1', s_axis_s2mm_cmd_tdata(16), tst);
        Eq("0000", s_axis_s2mm_cmd_tdata(67 downto 64), tst);
        Eq("0000", s_axis_s2mm_cmd_tdata(71 downto 68), tst);
        -- Wait for DATA VALID

        wait until s_axis_s2mm_tvalid = '1';
        -- Handshake data

        s_axis_s2mm_tready <= '1';
        wait until rising_edge(clk);
        s_axis_s2mm_tready <= '0';
        -- Check data content

        Eq(x"ABDABDAB", s_axis_s2mm_tdata, tst);
        Eq("1111", s_axis_s2mm_tkeep, tst);
        Eq('1', s_axis_s2mm_tlast, tst);

        expected_addr := std_logic_vector(unsigned(expected_addr) + 4);

        tst.end_test;
        ----
        -- TEST 2 : Streaming Multiple Samples
        ----
        tst.init_test("Continuous streaming");

        for i in 0 to NUM_SAMPLES - 1 loop
            ----
            -- Create input IQ
            ----
            wait until rising_edge(clk);
            iq_data     <= std_logic_vector(to_unsigned(i + 16#10#, 32));
            iq_data_new <= '1';

            wait until rising_edge(clk);
            iq_data_new <= '0';

            ----
            -- Wait for CMD VALID + handshake
            ----
            wait until s_axis_s2mm_cmd_tvalid = '1';
            s_axis_s2mm_cmd_tready <= '1';
            wait until rising_edge(clk);
            s_axis_s2mm_cmd_tready <= '0';

            ----
            -- Check CMD fields
            ----
            Eq(expected_addr, s_axis_s2mm_cmd_tdata(63 downto 32), tst);
            Eq(x"0004", s_axis_s2mm_cmd_tdata(15 downto 0), tst);
            Eq('1', s_axis_s2mm_cmd_tdata(16), tst);

            ----
            -- Wait for DATA VALID + handshake
            ----
            wait until s_axis_s2mm_tvalid = '1';
            s_axis_s2mm_tready <= '1';
            wait until rising_edge(clk);
            s_axis_s2mm_tready <= '0';

            ----
            -- Validate data beat
            ----
            Eq(std_logic_vector(to_unsigned(i + 16#10#, 32)), s_axis_s2mm_tdata, tst);
            Eq("1111", s_axis_s2mm_tkeep, tst);
            Eq('1', s_axis_s2mm_tlast, tst);

            ----
            -- Next address
            ----
            expected_addr := std_logic_vector(unsigned(expected_addr) + 4);
        end loop;

        tst.end_test;
        ----
        -- TEST 3 : TREADY Backpressure Test
        ----
        tst.init_test("TREADY stall behavior");

        wait until rising_edge(clk);
        iq_data     <= x"DEADBEEF";
        iq_data_new <= '1';

        wait until rising_edge(clk);
        iq_data_new <= '0';

        wait until s_axis_s2mm_cmd_tvalid = '1';
        s_axis_s2mm_cmd_tready <= '1';
        wait until rising_edge(clk);
        s_axis_s2mm_cmd_tready <= '0';

        -- STALL DATA BY HOLDING TREADY LOW
        wait until s_axis_s2mm_tvalid = '1';
        wait for 5 * CLK_PERIOD; -- stall window
        s_axis_s2mm_tready <= '1';
        wait until rising_edge(clk);
        s_axis_s2mm_tready <= '0';

        Eq(x"DEADBEEF", s_axis_s2mm_tdata, tst);
        Eq("1111", s_axis_s2mm_tkeep, tst);
        Eq('1', s_axis_s2mm_tlast, tst);

        tst.end_test;
        std.env.finish;
    end process;

    ----
    -- CLOCK 
    clk_proc : process
    begin
        clk <= '0';
        wait for CLK_PERIOD/2;
        clk <= '1';
        wait for CLK_PERIOD/2;
    end process;

    ----
    -- DUT INSTANTIATION
    uut : entity work.datamover_s2mm_cmdgen
        port map(
            clk                    => clk,
            rst                    => rst,
            iq_data                => iq_data,
            iq_data_new            => iq_data_new,
            s_axis_s2mm_cmd_tdata  => s_axis_s2mm_cmd_tdata,
            s_axis_s2mm_cmd_tvalid => s_axis_s2mm_cmd_tvalid,
            s_axis_s2mm_cmd_tready => s_axis_s2mm_cmd_tready,
            s_axis_s2mm_tdata      => s_axis_s2mm_tdata,
            s_axis_s2mm_tkeep      => s_axis_s2mm_tkeep,
            s_axis_s2mm_tlast      => s_axis_s2mm_tlast,
            s_axis_s2mm_tvalid     => s_axis_s2mm_tvalid,
            s_axis_s2mm_tready     => s_axis_s2mm_tready
        );

end architecture tb;
