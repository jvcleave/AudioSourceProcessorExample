//
//  AudioSourceProcessing.swift
//  AudioSourceProcessorExample
//
//  Created by jason van cleave on 2/22/26.
//

import Foundation

protocol AudioSourceProcessing
{
    func processURL(
        _ audioURL: URL,
        fps: Double
    ) async throws -> AudioSource?

    func combineAudioFiles(
        urls: [URL],
        fps: Double
    ) async throws -> URL?
}
