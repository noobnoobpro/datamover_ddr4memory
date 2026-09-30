--------------------------------------------------------------------------------
-- File:          data_mover.vhd
-- Description:   Datamover logic responsible for converting stream data to memory mapped and storing it into the DDR4 memory
--------------------------------------------------------------------------------
-- This module takes the stream raw data without addressing and parces it through the datamover IP which
-- takes the command for assigning address to the stream input and outputs the memory mapped data
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity datamover_s2mm_cmdgen is
    generic (
        DEST_ADDR_BASE : std_logic_vector(31 downto 0) := x"00000000" --> currently. DDR offset is now configured via signal_recorder Wishbone register 0x84.
    );
    port (
        clk                    : in std_logic;
        rst                    : in std_logic;

        --ddr offset
        ddr_offset             : in std_logic_vector(31 downto 0);

        -- DataMover S2MM command interface
        s_axis_s2mm_cmd_tdata  : out std_logic_vector(71 downto 0);
        s_axis_s2mm_cmd_tvalid : out std_logic;
        s_axis_s2mm_cmd_tready : in std_logic;

        -- IQ input from signal recorder
        iq_data                : in std_logic_vector(31 downto 0);
        iq_data_new            : in std_logic;
        iq_ready               : out std_logic; --> port to detect dataloss 
        iq_accepted            : out std_logic;

        -- DataMover S2MM data interface
        s_axis_s2mm_tdata      : out std_logic_vector(31 downto 0);
        s_axis_s2mm_tkeep      : out std_logic_vector(3 downto 0);
        s_axis_s2mm_tlast      : out std_logic;
        s_axis_s2mm_tvalid     : out std_logic;
        s_axis_s2mm_tready     : in std_logic
    );
end datamover_s2mm_cmdgen;
architecture Behavioral of datamover_s2mm_cmdgen is

    constant BTT_LEN             : natural                                := 16; -- log2(C_BURST_SIZE * (DATA_WIDTH / 8))
    constant ADDR_BUS_WIDTH      : natural                                := 32;
    --Number of commands we try to keep inside the datamover command FIFO 
    constant MAX_QUEUED_COMMANDS : natural                                := 4;
    -- DDR4 memory map address range (0x00000000 - 0xFFFFFFFF) 
    --number of bytes transferred by one Datamover command = 1 iq sample = 16 bits [I] + 16 bits [Q] = 32 bits = 4 bytes 
    constant TRANSFER_BYTES      : natural                                := 4;
    constant TYPE_INCR           : std_logic                              := '1';                                                    --A value of 1 means INCR access
    constant BTT_4B              : std_logic_vector(BTT_LEN - 1 downto 0) := std_logic_vector(to_unsigned(TRANSFER_BYTES, BTT_LEN)); -- 4 bytes being transferred per command  
    constant DDR_REGION_BYTES    : natural                                := 16#10000000#;                                           -- 256 MiB

    --function that generates a datamover command for given destination address
    function make_s2mm_cmd(
        addr : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable i_cmd_packet : std_logic_vector(71 downto 0) := (others => '0');
    begin
        -- Command generation
        i_cmd_packet(BTT_LEN - 1 downto 0)          := BTT_4B;
        i_cmd_packet(23)                            := TYPE_INCR;
        i_cmd_packet(30)                            := '1';
        i_cmd_packet(ADDR_BUS_WIDTH + 31 downto 32) := addr;
        return i_cmd_packet;
    end function;

    --function to allocate address space ensuring circular buffer 
    function next_circular_addr(
        current_addr : unsigned(ADDR_BUS_WIDTH - 1 downto 0);
        base_addr    : unsigned(ADDR_BUS_WIDTH - 1 downto 0)
    ) return unsigned is
        variable last_valid_start : unsigned(ADDR_BUS_WIDTH - 1 downto 0);
    begin
        last_valid_start :=
            base_addr + to_unsigned(DDR_REGION_BYTES - TRANSFER_BYTES, ADDR_BUS_WIDTH);

        if current_addr >= last_valid_start then
            return base_addr;
        else
            return current_addr + to_unsigned(TRANSFER_BYTES, ADDR_BUS_WIDTH);
        end if;
    end function;

    signal curr_addr                       : std_logic_vector(ADDR_BUS_WIDTH - 1 downto 0) := (others => '0');
    signal cmd_packet                      : std_logic_vector(71 downto 0)                 := (others => '0');
    signal cmd_valid                       : std_logic                                     := '0';
    signal cmd_credit                      : natural range 0 to MAX_QUEUED_COMMANDS        := 0;
    signal cmd_fire                        : std_logic;
    signal iq_latched                      : std_logic_vector(31 downto 0) := (others => '0');
    signal iq_pending                      : std_logic                     := '0';
    signal data_valid                      : std_logic;
    signal data_fire                       : std_logic;

    -- Debug mirror signals for ILA
    signal dbg_cmd_credit                  : std_logic_vector(2 downto 0);
    signal dbg_curr_addr                   : std_logic_vector(31 downto 0);

    attribute MARK_DEBUG                   : string;
    attribute KEEP                         : string;

    attribute MARK_DEBUG of cmd_valid      : signal is "TRUE";
    attribute MARK_DEBUG of cmd_fire       : signal is "TRUE";
    attribute MARK_DEBUG of data_valid     : signal is "TRUE";
    attribute MARK_DEBUG of data_fire      : signal is "TRUE";
    attribute MARK_DEBUG of iq_pending     : signal is "TRUE";
    attribute MARK_DEBUG of iq_data_new    : signal is "TRUE";
    attribute MARK_DEBUG of iq_ready       : signal is "TRUE";
    attribute MARK_DEBUG of iq_accepted    : signal is "TRUE";
    attribute MARK_DEBUG of dbg_cmd_credit : signal is "TRUE";
    attribute MARK_DEBUG of dbg_curr_addr  : signal is "TRUE";

    attribute KEEP of cmd_valid            : signal is "TRUE";
    attribute KEEP of cmd_fire             : signal is "TRUE";
    attribute KEEP of data_valid           : signal is "TRUE";
    attribute KEEP of data_fire            : signal is "TRUE";
    attribute KEEP of iq_pending           : signal is "TRUE";
    attribute KEEP of dbg_cmd_credit       : signal is "TRUE";
    attribute KEEP of dbg_curr_addr        : signal is "TRUE";

begin
    --debug signals 
    dbg_cmd_credit         <= std_logic_vector(to_unsigned(cmd_credit, dbg_cmd_credit'length));
    dbg_curr_addr          <= curr_addr;

    --command generation 
    s_axis_s2mm_cmd_tdata  <= cmd_packet;
    s_axis_s2mm_cmd_tvalid <= cmd_valid;

    cmd_fire               <= cmd_valid and s_axis_s2mm_cmd_tready;

    --data can only be sent when the following two conditions are satisfied 
    --1. An IQ sample is available to be sent 
    --2. Atleast there's one command queued in command FIFO 
    data_valid             <= '1' when iq_pending = '1' and cmd_credit > 0 else
        '0';

    s_axis_s2mm_tdata  <= iq_latched;
    s_axis_s2mm_tkeep  <= "1111";
    s_axis_s2mm_tlast  <= '1';
    s_axis_s2mm_tvalid <= data_valid;

    --IQ data being accepted by the datamover 
    data_fire          <= data_valid and s_axis_s2mm_tready;
    iq_accepted        <= data_fire;

    --in order to accept a new IQ sample one of the following two conditions need to be satisfied 
    --1. Current sample buffer needs to be empty ie) iq_pending = '0'(or) 
    --2. The current sample is consumend in the same clock cycle ie) data_fire ='1'
    --iq_ready <= '1' when iq_pending = '0' or data_fire = '1' else '0';
    iq_ready           <= '1' when iq_pending = '0' else
        '0';

    -- IQ capture (unchanged behavior)
    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                iq_pending <= '0';
                iq_latched <= (others => '0');
            else
                if data_fire = '1' then
                    iq_pending <= '0';
                    -- if iq_data_new = '1' then 
                    --     iq_latched <= iq_data;
                    --     iq_pending <= '1';
                    -- else
                    --     iq_pending <= '0';
                    -- end if;

                elsif iq_data_new = '1' and iq_pending = '0' then
                    iq_latched <= iq_data;
                    iq_pending <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Command queue implementation
    process (clk)
        variable v_credit         : integer;
        variable v_addr           : unsigned(ADDR_BUS_WIDTH - 1 downto 0);
        variable v_slot_available : boolean;
    begin
        if rising_edge(clk) then

            if rst = '1'then

                --curr_addr            <= DEST_ADDR_BASE; --> currently. DDR offset is now configured via signal_recorder Wishbone register 0x84.
                curr_addr  <= ddr_offset;
                cmd_credit <= 0;
                cmd_valid  <= '0';
                cmd_packet <= (others => '0');

            else

                v_credit := cmd_credit;
                v_addr   := unsigned(curr_addr);

                -- SEND_CMD : Issue the 72-bit AXI command
                -- A command is counted only when DataMover accepts it.
                if cmd_fire = '1' then
                    v_credit := v_credit + 1;

                    -- FINISH : Increment address
                    -- Address is incremented when command is accepted,
                    -- because the command has reserved this DDR address.
                    v_addr   := next_circular_addr(v_addr, unsigned(ddr_offset));
                end if;

                -- SEND_DATA : Send the 32-bit IQ sample
                -- One accepted IQ data beat consumes one queued command.
                if data_fire = '1' then
                    v_credit := v_credit - 1;
                end if;

                if v_credit < 0 then
                    v_credit := 0;
                elsif v_credit > MAX_QUEUED_COMMANDS then
                    v_credit := MAX_QUEUED_COMMANDS;
                end if;

                v_slot_available := (cmd_valid = '0') or (cmd_fire = '1');

                if v_slot_available and v_credit < MAX_QUEUED_COMMANDS then
                    cmd_packet <= make_s2mm_cmd(std_logic_vector(v_addr));
                    cmd_valid  <= '1';
                else
                    if cmd_fire = '1' then
                        cmd_valid <= '0';
                    end if;
                end if;

                curr_addr  <= std_logic_vector(v_addr);
                cmd_credit <= v_credit;
            end if;
        end if;
    end process;
end Behavioral;
