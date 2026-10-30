// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared types of the PLEA court: pleas, verdicts, sales, objections and the leaderboard.
interface IPleaCourt {
    enum Status {
        None,
        Pending,
        Approved,
        Denied,
        Closed,
        Withdrawn,
        Struck
    }

    struct Plea {
        address seller;
        uint128 amount;
        uint128 sold;
        uint64 submittedAt;
        uint64 decidedAt;
        uint64 windowExpiry;
        uint8 round;
        /// @dev True once the seller's one re-hearing is used: an appeal, or a fresh plea after a denial.
        bool appealed;
        Status status;
        uint16 approveVotes;
        uint16 denyVotes;
        uint16 medianScore;
        /// @dev The season the approval's points were awarded in; zero until approved.
        uint64 season;
    }

    struct Sale {
        uint256 pleaId;
        address seller;
        uint128 amount;
        uint64 executedAt;
        bool objected;
        /// @dev The season of the plea's points, which an upheld objection strikes.
        uint64 season;
    }

    struct Objection {
        uint256 saleId;
        address objector;
        uint64 openedAt;
        uint16 upholdVotes;
        uint16 dismissVotes;
        bool resolved;
        bool upheld;
        bool bondReturned;
    }

    struct Entry {
        address account;
        uint256 points;
    }
}
