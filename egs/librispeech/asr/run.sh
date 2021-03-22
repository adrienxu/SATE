#! /bin/bash

# Processing LibriSpeech Datasets

# Copyright 2021 Natural Language Processing Laboratory 
# Xu Chen (xuchenneu@163.com)

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
#set -u
set -o pipefail
export PYTHONIOENCODING=UTF-8

eval=1
time=$(date "+%m%d_%H%M")

stage=0
stop_stage=0

######## hardware ########
# devices
device=()
gpu_num=8
update_freq=1

root_dir=~/Code/st/fairseq
pwd_dir=$PWD

# dataset
src_lang=en
lang=${src_lang}

dataset=librispeech
task=speech_to_text
vocab_type=unigram
vocab_size=10000

data_dir=~/Code/st/data/${dataset}
test_subset=(dev-clean dev-other test-clean test-other)

# exp
extra_tag=
extra_parameter=
exp_tag=baseline
exp_name=

# config
train_config=asr_train_ctc.yaml
data_config=config.yaml

# training setting
fp16=0
max_tokens=40000
step_valid=0

# decoding setting
n_average=10
beam_size=5

. ./local/parse_options.sh || exit 1;

if [[ $step_valid -eq 1 ]]; then
    validate_interval=10000
    save_interval=10000
    no_epoch_checkpoints=1
    save_interval_updates=5000
    keep_interval_updates=3
else
    validate_interval=1
    keep_last_epochs=10
fi

# full path
train_config=$pwd_dir/conf/${train_config}
if [[ -z ${exp_name} ]]; then
    exp_name=$(basename ${train_config%.*})_${exp_tag}
    if [[ -n ${extra_tag} ]]; then
        exp_name=${exp_name}_${extra_tag}
    fi
fi

model_dir=$root_dir/../checkpoints/$dataset/$task/asr/${exp_name}

if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    echo "stage -1: Data Download"
    # pass
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 0: Data Preparation"
    cmd="python ${root_dir}/examples/speech_to_text/prep_librispeech_data.py
        --output-root ${data_dir} 
        --vocab-type ${vocab_type}
        --vocab-size ${vocab_size}"
    echo -e "\033[34mRun command: \n${cmd} \033[0m"
    [[ $eval -eq 1 ]] && eval $cmd
fi

if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    echo "stage 1: ASR Network Training"
    [[ ! -d $data_dir ]] && echo "The data dir $data_dir is not existing!" && exit 1;

    if [[ -z ${device} || ${#device[@]} -eq 0 ]]; then
		if [[ ${gpu_num} -eq 0 ]]; then
			device=()
		else
        	source ./local/utils.sh
        	device=$(get_devices $gpu_num 0)
		fi
    fi

    echo -e "dev=${device} data=$data_dir model=${model_dir}"

    if [[ ! -d ${model_dir} ]]; then
        mkdir -p ${model_dir}
    else
        echo "${model_dir} exists."
    fi

    cp ${BASH_SOURCE[0]} ${model_dir}
    cp ${PWD}/train.sh ${model_dir}
    cp ${train_config} ${model_dir}

    cmd="python3 -u ${root_dir}/fairseq_cli/train.py
        $data_dir
		--config-yaml ${data_config}
        --train-config ${train_config}
        --task speech_to_text
        --max-tokens ${max_tokens}
        --update-freq ${update_freq}
        --log-interval 100
        --save-dir ${model_dir}
        --tensorboard-logdir ${model_dir}"

    if [[ -n ${extra_parameter} ]]; then
        cmd="${cmd}
        ${extra_parameter}"
    fi
	if [[ ${gpu_num} -gt 0 ]]; then
		cmd="${cmd}
        --distributed-world-size $gpu_num
        --ddp-backend no_c10d"
	fi
    if [[ $fp16 -eq 1 ]]; then
        cmd="${cmd}
        --fp16"
    fi
    if [[ -n $no_epoch_checkpoints && $no_epoch_checkpoints -eq 1 ]]; then
        cmd="$cmd
        --no-epoch-checkpoints"
    fi
    if [[ -n $validate_interval ]]; then
        cmd="${cmd}
        --validate-interval $validate_interval "
    fi
    if [[ -n $save_interval ]]; then
        cmd="${cmd}
        --save-interval $save_interval "
    fi
    if [[ -n $keep_last_epochs ]]; then
        cmd="${cmd}
        --keep-last-epochs $keep_last_epochs "
    fi
    if [[ -n $save_interval_updates ]]; then
        cmd="${cmd}
        --save-interval-updates $save_interval_updates"
        if [[ -n $keep_interval_updates ]]; then
        cmd="${cmd}
        --keep-interval-updates $keep_interval_updates"
        fi
    fi

    echo -e "\033[34mRun command: \n${cmd} \033[0m"

    # save info
    log=./history.log
    echo "${time} | ${device} | $data_dir | ${model_dir} " >> $log
    cat $log | tail -n 50 > tmp.log
    mv tmp.log $log
    export CUDA_VISIBLE_DEVICES=${device}

    cmd="nohup ${cmd} >> ${model_dir}/train.log 2>&1 &"
    if [[ $eval -eq 1 ]]; then
		eval $cmd
		sleep 2s
		tail -n `wc -l ${model_dir}/train.log | awk '{print $1+1}'` -f ${model_dir}/train.log
	fi
fi
wait

if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    echo "stage 2: ASR Decoding"
    if [[ ${n_average} -ne 1 ]]; then
        # Average models
		dec_model=avg_${n_average}_checkpoint.pt

		cmd="python ${root_dir}/scripts/average_checkpoints.py
        --inputs ${model_dir}
        --num-epoch-checkpoints ${n_average}
        --output ${model_dir}/${dec_model}"
    	echo -e "\033[34mRun command: \n${cmd} \033[0m"
    	[[ $eval -eq 1 ]] && eval $cmd
	else
		dec_model=checkpoint_best.pt
	fi

    if [[ -z ${device} || ${#device[@]} -eq 0 ]]; then
		if [[ ${gpu_num} -eq 0 ]]; then
			device=()
		else
        	source ./local/utils.sh
        	device=$(get_devices $gpu_num 0)
		fi
    fi
    export CUDA_VISIBLE_DEVICES=${device}

	#tmp_file=$(mktemp ${model_dir}/tmp-XXXXX)
	#trap 'rm -rf ${tmp_file}' EXIT
	result_file=${model_dir}/decode_result
	[[ -f ${result_file} ]] && rm ${result_file}

	for subset in ${test_subset[@]}; do
        subset=${subset}
  		cmd="python ${root_dir}/fairseq_cli/generate.py
        ${data_dir}/$lang
        --config-yaml ${data_config}
        --gen-subset ${subset}
        --task speech_to_text
        --path ${model_dir}/${dec_model}
        --results-path ${model_dir}
        --max-tokens ${max_tokens}
        --beam ${beam_size}
        --scoring wer"
    	echo -e "\033[34mRun command: \n${cmd} \033[0m"

        if [[ $eval -eq 1 ]]; then
    	    eval $cmd
    	    tail -n 1 ${model_dir}/generate-${subset}.txt >> ${result_file}
        fi
	done
    cat ${result_file}
fi
