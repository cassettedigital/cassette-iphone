//
//  DeviceOwnershipMO+CoreDataProperties.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import CoreData
import Foundation

extension DeviceOwnershipMO {
  @nonobjc
  public class func fetchRequest() -> NSFetchRequest<DeviceOwnershipMO> {
    NSFetchRequest<DeviceOwnershipMO>(entityName: "DeviceOwnership")
  }

  @NSManaged
  public var cassetteLocalId: String
  @NSManaged
  public var mbid: String?
  @NSManaged
  public var filePath: String
  @NSManaged
  public var downloadedAt: Date
  @NSManaged
  public var fileSizeBytes: Int64
  @NSManaged
  public var subsonicTrackId: String?
  /// The hub version this copy was made from (the manifest's audio_version), or nil when
  /// the phone can't vouch for it (BUG-897): set as a replacement lands, or by the sweep once
  /// the hub's file date shows the copy came from that very file. Compared against the
  /// manifest so a re-rip that changes bytes without changing title/duration (invisible to
  /// cassetteLocalId by design) still gets noticed and re-fetched.
  @NSManaged
  public var contentFingerprint: String?
}
