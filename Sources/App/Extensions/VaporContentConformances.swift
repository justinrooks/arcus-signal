//
//  VaporContentConformances.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 7/8/26.
//

import Vapor
import ArcusCore

extension StormSetupCurrentResponse: @retroactive Content {}
extension StormSetupCurrentSetupResponse: @retroactive Content {}
extension StormSetupTornadoIngredientsResponse: @retroactive Content {}
extension TornadoViabilityReport: @retroactive Content {}
extension TornadoViabilityDetails: @retroactive Content {}

extension StormSetupCentroid: @retroactive Content {}
extension StormSetupSourceMetadata: @retroactive Content {}
extension StormSetupHrrrBoundingBox: @retroactive Content {}
extension IngredientFreshness: @retroactive Content {}
extension TornadoRawParameters: @retroactive Content {}
extension DirectionSpeed: @retroactive Content {}
extension TornadoRawParameterDiagnostic: @retroactive Content {}
extension TornadoIngredientAssessment: Content {}
extension AnvilAnalyzeProfileResponse: @retroactive Content {}
extension AnvilEffectiveLayerDTO: @retroactive Content {}
extension AnvilQualityDTO: @retroactive Content {}
extension AnvilStormMotionDTO: @retroactive Content {}
extension AnvilBunkersRightStormMotionDTO: @retroactive Content {}
