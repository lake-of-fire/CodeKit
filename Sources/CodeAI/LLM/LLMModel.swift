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
    @Published var text = ""
    
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
    
    public func loadModel(llm: LLMConfiguration) async throws -> Bool? {
        guard let downloadable = llm.downloadable else { return nil }
        await DownloadController.shared.ensureDownloaded(download: downloadable)
        let modelURL = downloadable.localDestination
        chat = AI(_modelPath: modelURL.absoluteString)
        //            if (chat_config!["warm_prompt"] != nil){
        //                model_context_param.warm_prompt = chat_config!["warm_prompt"]! as! String
        //            }
        
        //Set mode linference and try to load model
        var model_load_res: Bool? = false
//        model_context_param.use_metal = llm.canUseMetal
//        model_context_param.useMlock = false
//        model_context_param.useMMap = true
        
        let model_sample_params = ModelSampleParams(n_batch: Int32(llm.nBatch ?? 512), temp: Float(llm.temperature), top_k: Int32(llm.topK ?? 40), top_p: Float(llm.topP ?? 0.95), tfs_z: ModelSampleParams.default.tfs_z, typical_p: ModelSampleParams.default.typical_p, repeat_penalty: Float(llm.repeatPenalty ?? 1.1), repeat_last_n: Int32(llm.repeatLastN ?? 64), frequence_penalty: ModelSampleParams.default.frequence_penalty, presence_penalty: ModelSampleParams.default.presence_penalty, mirostat: ModelSampleParams.default.mirostat, mirostat_tau: ModelSampleParams.default.mirostat_tau, mirostat_eta: ModelSampleParams.default.mirostat_eta, penalize_nl: ModelSampleParams.default.penalize_nl, use_metal: llm.canUseMetal)
        chat?.model.sampleParams = model_sample_params
        let threads = Int32(min(4, ProcessInfo().processorCount))
        let model_context_param = ModelAndContextParams(context: Int32(llm.context ?? 1024), parts: ModelAndContextParams.default.parts, seed: ModelAndContextParams.default.seed, numberOfThreads: threads, n_batch: Int32(llm.nBatch ?? 512), f16Kv: ModelAndContextParams.default.f16Kv, logitsAll: ModelAndContextParams.default.logitsAll, vocabOnly: ModelAndContextParams.default.vocabOnly, useMlock: false, useMMap: true, embedding: ModelAndContextParams.default.embedding)
        chat?.model.contextParams = model_context_param
        
        do {
            if llm.modelInference == "llama" {
                if modelURL.pathExtension.lowercased() == "gguf" {
                    try model_load_res = chat?.loadModel(ModelInference.LLama_gguf, contextParams: model_context_param)
                }
//                else {
//                    try model_load_res = chat?.loadModel(ModelInference.LLama_bin, contextParams: model_context_param)
//                }
                //            } else if llm.modelInference == "gptneox" {
                //                    if modelURL.hasSuffix(".gguf"){
                //                        try model_load_res = self.chat?.loadModel(ModelInference.LLama_gguf,contextParams: model_context_param)
                //                    }else{
                //                        try model_load_res = self.chat?.loadModel(ModelInference.GPTNeox,contextParams: model_context_param)
                //                    }
//            } else if modelURL.pathExtension.lowercased() == "rwkv" {
//                try model_load_res = chat?.loadModel(ModelInference.RWKV,contextParams: model_context_param)
//                //                } else if modelURL.pathExtension.lowercased() == "gpt2" {
//                //                    try model_load_res = self.chat?.loadModel(ModelInference.GPT2,contextParams: model_context_param)
//                //                    self.chat?.model.reverse_prompt.append("<|endoftext|>")
//            } else if llm.modelInference == "replit" {
//                try model_load_res = self.chat?.loadModel(ModelInference.Replit, contextParams: model_context_param)
//                self.chat?.model.reverse_prompt.append("<|endoftext|>")
//            } else if llm.modelInference == "starcoder" {
//                if modelURL.pathExtension == "gguf" {
//                    try model_load_res = chat?.loadModel(ModelInference.LLama_gguf, contextParams: model_context_param)
//                } else {
//                    try model_load_res = chat?.loadModel(ModelInference.Starcoder, contextParams: model_context_param)
//                }
//                chat?.model.reverse_prompt.append("<|endoftext|>")
            }
        } catch {
            print(error)
            throw error
        }
        if chat?.model == nil || chat?.model.context == nil {
            return nil
        }
        
        if !llm.reversePrompt.isEmpty {
            let splited_revrse_prompt = llm.reversePrompt.components(separatedBy: [";"])
            for word in splited_revrse_prompt{
                let trimed_word = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimed_word == "" {
                    continue
                }
                var exist = false
                for r_word in chat!.model.reverse_prompt {
                    if r_word == trimed_word{
                        exist = true
                        break
                    }
                }
                if !exist {
                    chat?.model.reverse_prompt.append(trimed_word)
                }
            }
        }

        print(model_load_res.debugDescription)
//        print(model_sample_param)
//        print(model_context_param)
        let modelLowercase = modelURL.deletingPathExtension().lastPathComponent.lowercased()
        //Set prompt model if in config or try to set promt format by filename
        if (!llm.promptFormat.isEmpty && llm.promptFormat != "auto"
            && llm.promptFormat != "{{prompt}}") {
            chat?.model.custom_prompt_format = llm.promptFormat
            chat?.model.promptFormat = .Custom
        } else {
            if modelLowercase.contains("dolly") {
                self.chat?.model.promptFormat = .Dolly_b3;
            } else if modelLowercase.contains("stable") {
                chat?.model.promptFormat = .StableLM_Tuned
                chat?.model.reverse_prompt.append("<|USER|>")
            } else if (!llm.modelInference.isEmpty && llm.modelInference == "llama") ||
                        modelLowercase.contains("llama") ||
                        modelLowercase.contains("alpaca") ||
                        modelLowercase.contains("vic") {
                //            self.chat?.model.promptStyle = .LLaMa
                chat?.model.promptFormat = .LLaMa
            } else if modelLowercase.contains("rp-") && modelLowercase.contains("chat") {
                chat?.model.promptFormat = .RedPajama_chat
            } else {
                chat?.model.promptFormat = .None
            }
        }
        return true
    }
    
    public func stopPrediction(is_error: Bool = false) {
        chat?.flagExit = true
        total_sec = Double((DispatchTime.now().uptimeNanoseconds - start_predicting_time.uptimeNanoseconds)) / 1_000_000_000
        predicting = false
        numberOfTokens = 0
        AI_typing = 0
//        save_chat_history(self.messages,self.chat_name+".json")
    }
    
    private func processPredictedStr(_ str: String, _ time: Double) -> Bool {
        var check = true
        for stop_word in chat?.model.reverse_prompt ?? [] {
            if str == stop_word {
                self.stopPrediction()
                check = false
                break
            }
            if text.hasSuffix(stop_word) {
                stopPrediction()
                check = false
                if stop_word.count > 0 && text.count > stop_word.count {
                    text.removeLast(stop_word.count)
                }
            }
        }
        if check && chat?.flagExit != true {
            text += str
            //                    self.AI_typing += str.count
            self.AI_typing += 1
            self.numberOfTokens += 1
            self.total_sec += time
//            if (self.numberOfTokens>self.maxToken){
//                self.stop_predict()
//            }
        } else {
//            print("chat ended.")
        }
        return check
    }
    
    public func send(message inputText: String, systemPrompt: String, messageHistory: [(String, String)], llm: LLMConfiguration) async throws -> String {
        if llm.modelDownloadURL != modelURL || (llm.context ?? 1024) != chat?.model.contextParams.context ?? -1 || (llm.nBatch ?? 512) != chat?.model.contextParams.n_batch ?? -1 {
            stopPrediction()
            chat = nil
            state = .none
            text = ""
            let old_typing = AI_typing
            while AI_typing == old_typing {
                AI_typing = -Int.random(in: 0..<100000)
            }
        } else if predicting {
            stopPrediction()
        }
        
        AI_typing += 1
        
        if chat == nil {
            state = .loading
            do {
                let res = try await loadModel(llm: llm)
                if res == nil {
                    state = .completed
                    stopPrediction(is_error: true)
                    throw LLMError.loadFailure
                }
                state = .completed
            } catch {
                state = .completed
                stopPrediction(is_error: true)
                throw error
            }
        }
        
        chat?.flagExit = false
        text = ""
        numberOfTokens = 0
        total_sec = 0.0
        predicting = true
        start_predicting_time = DispatchTime.now()
        
        try chat?.reinitializeSystemPrompt(systemPrompt)
        if !messageHistory.isEmpty {
            try chat?.conversationHistory(allMessages: messageHistory)
        }
        try await withCheckedThrowingContinuation { continuation in
            chat?.conversation(inputText, { [weak self] str, time in
                _ = self?.processPredictedStr(str, time)
            }, { [weak self] final_str in
                guard let self = self else { return }
                //                print(final_str)
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
                continuation.resume()
            })
        }
        return text
    }
}
