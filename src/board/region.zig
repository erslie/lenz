pub const Region = struct { base: u64, size: u64 };

// Location of PCI Express (ECAM style)
pub const Pci = struct {
    ecam_base: usize,
    ecam_size: usize,
    mmio_base: u64,
    mmio_size: u64,
};
