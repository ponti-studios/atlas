import Foundation
import FlightCore
import GeoCore
import ParcelCore
import TransitCore
import UtilityCore
import WalksCore

public typealias GeoCoordinate = GeoCore.GeoCoordinate
public typealias GeoRegion = GeoCore.GeoCoordinateRegion
public typealias GeoBounds = GeoCore.GeoBounds
public typealias RouteGeometry = GeoCore.RouteGeometry

public typealias WalkRoute = WalksCore.WalkRoute
public typealias RouteLocation = WalksCore.RouteLocation
public typealias WalkRouteSummary = WalksCore.WalkRouteSummary
public typealias WalkSearchFilter = WalksCore.WalkSearchFilter
public typealias WalkRoutePageCursor = WalksCore.WalkRoutePageCursor
public typealias WalkMonth = WalksCore.WalkMonth
public typealias WalkRouteSummaryPage = WalksCore.WalkRouteSummaryPage
public typealias WalkMetadata = WalksCore.WalkMetadata
public typealias HealthWorkout = WalksCore.HealthWorkout
public typealias HealthWalkArchive = WalksCore.HealthWalkArchive

public typealias Flight = FlightCore.Flight
public typealias AirportCatalog = FlightCore.AirportCatalog
public typealias Parcel = ParcelCore.Parcel
public typealias ParcelProviding = ParcelCore.ParcelProviding
public typealias TFLStation = TransitCore.TFLStation
public typealias JamCam = TransitCore.JamCam
public typealias JamCamProviding = TransitCore.JamCamProviding
public typealias JamCamError = TransitCore.JamCamError
public typealias TFLJamCamClient = TransitCore.TFLJamCamClient

public typealias CSVTable = UtilityCore.CSVTable
public typealias StableID = UtilityCore.StableID
