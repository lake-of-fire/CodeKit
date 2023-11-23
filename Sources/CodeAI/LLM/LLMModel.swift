//
//  ChatViewModel.swift
//  AlpacaChatApp
//
//  Created by Yoshimasa Niwa on 3/19/23.
//

import SwiftUI
import os
import SwiftLlama
import SwiftUIDownloads
import CodeCore

@MainActor
final public class LLMModel: ObservableObject {
    public static var shared: LLMModel = {
        LLMModel()
    }()
    
    enum State {
        case none
        case loading
        case completed
    }
    @Published var AI_typing = 0
    public var chat: AI?
    public var modelURL: String
    public var maxToken = 512
    public var numberOfTokens = 0
    public var total_sec = 0.0
    public var predicting = false
    //    public var model_name = "llama-7b-q5_1.bin"
    //    public var model_name = "stablelm-tuned-alpha-3b-ggml-model-q5_1.bin"
//    public var avalible_models: [String]
    public var start_predicting_time = DispatchTime.now()

    //    public var title:String = ""
    
    @Published var state: State = .none
//    @Published var text = ""
    
    public enum LLMError: Error {
        case loadFailure
        case unknown(message: String)
    }
    
    public init() {
        chat = nil
        modelURL = ""
//        avalible_models = []
    }
    
//    func _get_avalible_models(){
//        self.avalible_models = get_avalible_models()!
//    }
    
    private func refreshModelSampleParams(llm: LLMConfiguration) async {
        let model_sample_params = ModelSampleParams(n_batch: Int32(llm.nBatch ?? 512), temp: Float(llm.temperature), top_k: Int32(llm.topK ?? 40), top_p: Float(llm.topP ?? 0.95), tfs_z: ModelSampleParams.default.tfs_z, typical_p: ModelSampleParams.default.typical_p, repeat_penalty: Float(llm.repeatPenalty ?? 1.1), repeat_last_n: Int32(llm.repeatLastN ?? 64), frequence_penalty: ModelSampleParams.default.frequence_penalty, presence_penalty: ModelSampleParams.default.presence_penalty, mirostat: ModelSampleParams.default.mirostat, mirostat_tau: ModelSampleParams.default.mirostat_tau, mirostat_eta: ModelSampleParams.default.mirostat_eta, penalize_nl: ModelSampleParams.default.penalize_nl)
        await chat?.model.sampleParams = model_sample_params
    }
    
    @MainActor
    public func loadModel(llm: LLMConfiguration) async throws {
        guard let downloadable = llm.downloadable else {
            throw ModelError.modelNotFound(llm.name)
        }
        await DownloadController.shared.ensureDownloaded(download: downloadable)
        let modelURL = downloadable.localDestination
        chat = AI(_modelPath: modelURL.standardizedFileURL.path)
        //            if (chat_config!["warm_prompt"] != nil){
        //                model_context_param.warm_prompt = chat_config!["warm_prompt"]! as! String
        //            }
        
        //Set mode linference and try to load model
        var model_load_res: Bool? = false
//        model_context_param.use_metal = llm.canUseMetal
//        model_context_param.useMlock = false
//        model_context_param.useMMap = true
        
        let threads = Int32(min(4, ProcessInfo().processorCount))
        let model_context_param = ModelAndContextParams(context: Int32(llm.context ?? 1024), parts: ModelAndContextParams.default.parts, seed: ModelAndContextParams.default.seed, numberOfThreads: threads, n_batch: Int32(llm.nBatch ?? 512), f16Kv: ModelAndContextParams.default.f16Kv, logitsAll: ModelAndContextParams.default.logitsAll, vocabOnly: ModelAndContextParams.default.vocabOnly, useMlock: false, useMMap: true, useMetal: llm.canUseMetal, embedding: ModelAndContextParams.default.embedding)
        
        do {
            if llm.modelInference == "llama" {
                if modelURL.pathExtension.lowercased() == "gguf" {
                    try await chat?.loadModel(ModelInference.LLama_gguf, contextParams: model_context_param)
                } else {
                    throw ModelLoadError.modelLoadError
                }
            }
        } catch {
            print(error)
            throw error
        }
//        if chat?.model == nil || chat?.model.context == nil {
//            return nil
//        }
        
        await refreshModelSampleParams(llm: llm)
        await chat?.model.contextParams = model_context_param
        await chat?.model.promptFormat = llm.promptFormat
        await chat?.model.systemFormat = llm.systemFormat
    }
    
    public func stopPrediction(isError: Bool = false, isStopWord: Bool = false) async {
        chat?.didFlagExitDueToStopWord = isStopWord
        await chat?.stop()
        total_sec = Double((DispatchTime.now().uptimeNanoseconds - start_predicting_time.uptimeNanoseconds)) / 1_000_000_000
        predicting = false
        numberOfTokens = 0
        AI_typing = 0
//        save_chat_history(self.messages,self.chat_name+".json")
    }
    
    @MainActor
    private func processPredictedStr(_ str: String, textSoFar: String, time: Double, stopWords: [String]) async -> (Bool, String) {
        var check = false
        var processedTextSoFar = textSoFar
        for stopWord in stopWords {
            if str == stopWord {
                await stopPrediction(isStopWord: true)
                check = true
                break
            } else if textSoFar.hasSuffix(stopWord) {
                await stopPrediction(isStopWord: true)
                check = true
                if stopWord.count > 0 && processedTextSoFar.count > stopWord.count {
                    processedTextSoFar.removeLast(stopWord.count)
                }
            }
        }
        if !check && chat?.didFlagExit != true {
            //                    self.AI_typing += str.count
            self.AI_typing += 1
            self.numberOfTokens += 1
            self.total_sec += time
//            if (self.numberOfTokens>self.maxToken){
//                self.stop_predict()
//            }
//        } else {
//            print("chat ended.")
        }
        return (check, processedTextSoFar)
    }
    
    @MainActor
    public func send(message inputText: String, systemPrompt: String, messageHistory: [(String, String)], llm: LLMConfiguration) async throws -> String {
        await Task {
            if llm.modelDownloadURL != modelURL || (llm.context ?? 1024) != chat?.context ?? -1 || (llm.nBatch ?? 512) != chat?.nBatch ?? -1 {
                await stopPrediction()
                chat = nil
                state = .none
//                text = ""
                let old_typing = AI_typing
                while AI_typing == old_typing {
                    AI_typing = -Int.random(in: 0..<100000)
                }
            } else if predicting {
                await stopPrediction()
            }
        }.value
        
        AI_typing += 1
        
        if chat == nil {
            state = .loading
            do {
                try await loadModel(llm: llm)
                state = .completed
            } catch {
                state = .completed
                await stopPrediction(isError: true)
                throw error
            }
        }
        
        await refreshModelSampleParams(llm: llm)
//        await print(chat?.model.contextParams)
//        await print(chat?.model.sampleParams)
//        await print(chat?.model.systemFormat)
//        await print(chat?.model.promptFormat)
        
//        text = ""
        numberOfTokens = 0
        total_sec = 0.0
        predicting = true
        start_predicting_time = DispatchTime.now()
        
        try await chat?.reinitializeSystemPrompt(systemPrompt)
        if !messageHistory.isEmpty {
            try await chat?.conversationHistory(allMessages: messageHistory)
        }
        
        let stopWords = Array(llm.stopWords)
        let resp = try await chat?.conversation(inputText, { [weak self] str, textSoFar, time in
            return await self?.processPredictedStr(str, textSoFar: textSoFar, time: time, stopWords: stopWords)
        })
        print("## GOT RESP: \(resp ?? "[no resp]")")
        AI_typing = 0
        //                total_sec = Double((DispatchTime.now().uptimeNanoseconds - self.start_predicting_time.uptimeNanoseconds)) / 1_000_000_000
        //                if chat_name == chat?.chatName && chat?.flagExit != true {
        //                    message.state = .predicted(totalSecond: self.total_sec)
        //                    self.messages[messageIndex] = message
        //                } else {
        //                    print("chat ended.")
        //                }
        predicting = false
        numberOfTokens = 0
        //                if final_str.hasPrefix("[Error]") {
        //                    Message(sender: .system, state: .error, inputText: "Eval \(final_str)")
        //                }
        //                save_chat_history(self.messages,self.chat_name+".json")
        guard (chat?.didFlagExitDueToStopWord == true || chat?.didFlagExit != true), let resp = resp else {
            throw LLMError.unknown(message: "No response or AI exited")
        }
        return resp
    }
}
